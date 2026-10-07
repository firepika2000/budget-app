"""Authenticated, money-neutral bank-statement import review endpoints."""
from __future__ import annotations

from datetime import date, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from .database import get_db
from .dependencies import get_current_user
from .import_candidates import CSVMapping, ImportCandidate, ImportValidationError, parse_csv_candidates
from .import_formats import parse_ofx_candidates, parse_pdf_candidates, parse_qif_candidates
from .import_matching import review_candidates
from .import_review import load_match_observations
from .import_staging import cancel_staged_batch, get_staged_batch, list_staged_batches, stage_candidates
from .models import ImportBatch, Transaction, User
from .schemas import (
    StatementImportApproveRequest,
    StatementImportCancelRequest,
    StatementImportListResponse,
    StatementImportResponse,
    StatementImportUndoRequest,
    TransactionCreate,
)
from .budgeting_routes import create_transaction_in_session, require_budget_capability, void_transaction_in_session
from .import_staging import claim_staged_batch_for_approval


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/accounts/{account_id}/statement-imports")

# ISO 4217 currencies whose ordinary minor-unit exponent differs from two. The
# import boundary owns this deterministic conversion; clients never choose it.
_ZERO_DIGIT = {"BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"}
_THREE_DIGIT = {"BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"}


def _currency_scale(code: str) -> int:
    return 0 if code in _ZERO_DIGIT else 3 if code in _THREE_DIGIT else 2


def _candidates(batch: ImportBatch) -> list[ImportCandidate]:
    return [ImportCandidate(
        source_row=row["source_row"],
        occurred_on=date.fromisoformat(row["occurred_on"]),
        amount_minor=row["amount_minor"],
        payee=row["payee"],
        memo=row["memo"],
    ) for row in batch.candidates]


def _response(db: Session, user: User, budget_id: str, batch: ImportBatch,
              match_window_days: int) -> dict:
    candidates = _candidates(batch)
    start = min(row.occurred_on for row in candidates) - timedelta(days=match_window_days)
    end = max(row.occurred_on for row in candidates) + timedelta(days=match_window_days)
    observations = load_match_observations(
        db, user=user, budget_id=budget_id, account_id=batch.account_id,
        start_date=start, end_date=end,
    )
    reviews = {row.source_row: row for row in review_candidates(
        candidates, observations, date_window_days=match_window_days,
    )}
    return {
        "id": batch.id, "budget_id": batch.budget_id, "account_id": batch.account_id,
        "status": batch.status, "version": batch.version,
        "source_format": batch.source_format, "candidate_count": batch.candidate_count,
        "created_at": batch.created_at,
        "candidates": [{
            "source_row": row.source_row, "occurred_on": row.occurred_on,
            "amount_minor": row.amount_minor, "payee": row.payee, "memo": row.memo,
            "exact_transaction_ids": list(reviews[row.source_row].exact_transaction_ids),
            "possible_transaction_ids": list(reviews[row.source_row].possible_transaction_ids),
            "suggestions_truncated": reviews[row.source_row].suggestions_truncated,
            "duplicate_source_row": reviews[row.source_row].duplicate_source_row,
            "approval_action": batch.candidates[index].get("approval_action"),
            "posted_transaction_id": batch.candidates[index].get("posted_transaction_id"),
            "reversal_transaction_id": batch.candidates[index].get("reversal_transaction_id"),
        } for index, row in enumerate(candidates)],
    }


@router.get("", response_model=StatementImportListResponse)
def list_statement_imports(
    budget_id: str, account_id: str,
    limit: int = Query(default=25, ge=1, le=100),
    offset: int = Query(default=0, ge=0, le=100_000),
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict:
    batches, has_more = list_staged_batches(
        db, user=user, budget_id=budget_id, account_id=account_id,
        limit=limit, offset=offset,
    )
    return {
        "items": [{
            "id": batch.id, "budget_id": batch.budget_id, "account_id": batch.account_id,
            "status": batch.status, "version": batch.version,
            "source_format": batch.source_format, "candidate_count": batch.candidate_count,
            "created_at": batch.created_at,
        } for batch in batches],
        "has_more": has_more,
        "next_offset": offset + len(batches) if has_more else None,
    }


@router.post("", response_model=StatementImportResponse, status_code=status.HTTP_201_CREATED)
def stage_statement_import(
    budget_id: str,
    account_id: str,
    content: bytes = Body(..., media_type="application/octet-stream"),
    source_format: Literal["csv", "ofx", "qfx", "qif", "pdf"] = Header(..., alias="X-Statement-Format"),
    currency_code: str = Header(..., alias="X-Statement-Currency"),
    date_column: Optional[str] = Header(default=None, alias="X-CSV-Date-Column"),
    amount_column: Optional[str] = Header(default=None, alias="X-CSV-Amount-Column"),
    payee_column: Optional[str] = Header(default=None, alias="X-CSV-Payee-Column"),
    memo_column: Optional[str] = Header(default=None, alias="X-CSV-Memo-Column"),
    debit_column: Optional[str] = Header(default=None, alias="X-CSV-Debit-Column"),
    credit_column: Optional[str] = Header(default=None, alias="X-CSV-Credit-Column"),
    date_order: str = Header(default="ymd", alias="X-Statement-Date-Order"),
    delimiter: str = Header(default=",", alias="X-CSV-Delimiter"),
    match_window_days: int = Query(default=2, ge=0, le=7),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    normalized_currency = currency_code.strip().upper()
    try:
        scale = _currency_scale(normalized_currency)
        if source_format == "csv":
            if date_column is None or payee_column is None:
                raise ImportValidationError("CSV date and payee columns are required")
            candidates = parse_csv_candidates(content, CSVMapping(
                date_column=date_column, amount_column=amount_column,
                payee_column=payee_column, memo_column=memo_column,
                debit_column=debit_column, credit_column=credit_column,
                date_order=date_order, delimiter=delimiter,
            ), scale=scale)
        elif source_format in {"ofx", "qfx"}:
            candidates = parse_ofx_candidates(content, scale=scale)
        elif source_format == "qif":
            candidates = parse_qif_candidates(content, scale=scale, date_order=date_order)
        else:
            candidates = parse_pdf_candidates(content, scale=scale, date_order=date_order)
        batch = stage_candidates(
            db, user=user, budget_id=budget_id, account_id=account_id,
            currency_code=normalized_currency, candidates=candidates, source_format=source_format,
        )
        response = _response(db, user, budget_id, batch, match_window_days)
        db.commit()
        return response
    except ImportValidationError as error:
        raise HTTPException(status_code=422, detail=str(error)) from None


@router.get("/{batch_id}", response_model=StatementImportResponse)
def get_statement_import(
    budget_id: str, account_id: str, batch_id: str,
    match_window_days: int = Query(default=2, ge=0, le=7),
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict:
    batch = get_staged_batch(db, user=user, budget_id=budget_id, batch_id=batch_id)
    if batch.account_id != account_id:
        raise HTTPException(status_code=404, detail="Import batch not found")
    return _response(db, user, budget_id, batch, match_window_days)


@router.post("/{batch_id}/cancel", response_model=StatementImportResponse)
def cancel_statement_import(
    budget_id: str, account_id: str, batch_id: str, body: StatementImportCancelRequest,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict:
    batch = get_staged_batch(db, user=user, budget_id=budget_id, batch_id=batch_id)
    if batch.account_id != account_id:
        raise HTTPException(status_code=404, detail="Import batch not found")
    batch = cancel_staged_batch(
        db, user=user, budget_id=budget_id, batch_id=batch_id,
        expected_version=body.expected_version,
    )
    response = _response(db, user, budget_id, batch, 2)
    db.commit()
    return response


@router.post("/{batch_id}/approve", response_model=StatementImportResponse)
def approve_statement_import(
    budget_id: str, account_id: str, batch_id: str, body: StatementImportApproveRequest,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict:
    batch = get_staged_batch(db, user=user, budget_id=budget_id, batch_id=batch_id)
    if batch.account_id != account_id:
        raise HTTPException(status_code=404, detail="Import batch not found")
    candidates = {row.source_row: row for row in _candidates(batch)}
    if set(candidates) != {item.source_row for item in body.items}:
        raise HTTPException(status_code=422, detail="Review every imported row before approval")
    # Claim before any financial write. A rollback restores review state if any
    # canonical transaction fails validation or authorization.
    batch = claim_staged_batch_for_approval(
        db, user=user, budget_id=budget_id, batch_id=batch_id,
        expected_version=body.expected_version,
    )
    choices = {item.source_row: item for item in body.items}
    stored_rows = []
    for stored in batch.candidates:
        candidate = candidates[stored["source_row"]]
        choice = choices[candidate.source_row]
        approved = dict(stored)
        approved["approval_action"] = choice.action
        if choice.action == "post":
            transaction = create_transaction_in_session(
                budget_id,
                TransactionCreate(
                    account_id=account_id, category_id=choice.category_id,
                    amount_minor=candidate.amount_minor, occurred_on=candidate.occurred_on,
                    payee_name=candidate.payee, memo=candidate.memo, is_cleared=True,
                ),
                user=user, db=db,
            )
            approved["posted_transaction_id"] = transaction.id
        stored_rows.append(approved)
    batch.candidates = stored_rows
    db.flush()
    response = _response(db, user, budget_id, batch, 2)
    db.commit()
    return response


@router.post("/{batch_id}/undo", response_model=StatementImportResponse)
def undo_statement_import(
    budget_id: str, account_id: str, batch_id: str, body: StatementImportUndoRequest,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "delete_transaction")
    visible = get_staged_batch(db, user=user, budget_id=budget_id, batch_id=batch_id)
    if visible.account_id != account_id:
        raise HTTPException(status_code=404, detail="Import batch not found")
    batch = db.scalar(select(ImportBatch).where(
        ImportBatch.id == batch_id, ImportBatch.budget_id == budget_id,
    ).with_for_update())
    if batch is None or batch.version != body.expected_version:
        raise HTTPException(status_code=409, detail="Statement import changed; reload before undoing")
    if batch.status != "approved":
        raise HTTPException(status_code=409, detail="Only an approved statement import can be undone")
    posted_ids = [row.get("posted_transaction_id") for row in batch.candidates if row.get("approval_action") == "post"]
    if not posted_ids:
        raise HTTPException(status_code=409, detail="This import did not post any transactions")
    if any(row.get("reversal_transaction_id") for row in batch.candidates):
        raise HTTPException(status_code=409, detail="This statement import has already been undone")
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id, Transaction.id.in_(posted_ids),
    ).with_for_update()))
    by_id = {item.id: item for item in transactions}
    if len(by_id) != len(posted_ids):
        raise HTTPException(status_code=409, detail="One or more imported transactions no longer exists")
    reversals = {}
    for transaction_id in posted_ids:
        reversal = void_transaction_in_session(
            budget=budget, original=by_id[transaction_id],
            reason=f"Undo statement import {batch.id}", user=user, db=db,
        )
        reversals[transaction_id] = reversal.id
    batch.candidates = [dict(row, reversal_transaction_id=reversals.get(row.get("posted_transaction_id")))
                        if row.get("posted_transaction_id") in reversals else dict(row)
                        for row in batch.candidates]
    batch.version += 1
    db.flush()
    response = _response(db, user, budget_id, batch, 2)
    db.commit()
    return response
