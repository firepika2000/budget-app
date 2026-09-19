"""Owned money-neutral staging. Callers own commit/rollback; no posting here."""
from __future__ import annotations

from datetime import date

from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from .access import can_access_resource
from .budgeting_routes import require_budget_capability
from .import_candidates import ImportCandidate, MAX_ROWS
from .models import Account, ImportBatch, User


def _require_account(db: Session, user: User, budget_id: str, account_id: str):
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    require_budget_capability(db, user, budget_id, "create_transaction")
    account = db.scalar(select(Account).where(Account.id == account_id, Account.budget_id == budget_id))
    if account is None or account.is_closed or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    return budget


def stage_candidates(db: Session, *, user: User, budget_id: str, account_id: str,
                     currency_code: str, candidates: list[ImportCandidate], source_format: str) -> ImportBatch:
    """Accept normalized minor units, never caller-selected decimal scale.

    File adapters must resolve the authoritative currency scale before calling.
    This internal service is not an HTTP endpoint accepting unchecked JSON.
    """
    budget = _require_account(db, user, budget_id, account_id)
    if currency_code != budget.currency_code or source_format not in {"csv", "ofx", "qfx", "qif"}:
        raise HTTPException(status_code=422, detail="Invalid import currency or format")
    if not 1 <= len(candidates) <= MAX_ROWS:
        raise HTTPException(status_code=422, detail="Import must contain 1 to 10000 candidates")
    rows = []
    seen = set()
    for row in candidates:
        if (type(row.source_row) is not int or row.source_row < 1 or row.source_row in seen
                or type(row.amount_minor) is not int or not -(2**63) <= row.amount_minor <= 2**63 - 1
                or type(row.occurred_on) is not date or not isinstance(row.payee, str)
                or not isinstance(row.memo, str) or len(row.payee) > 150 or len(row.memo) > 500):
            raise HTTPException(status_code=422, detail="Invalid normalized import candidate")
        seen.add(row.source_row)
        rows.append(dict(source_row=row.source_row, occurred_on=row.occurred_on.isoformat(),
                         amount_minor=row.amount_minor, payee=row.payee, memo=row.memo))
    batch = ImportBatch(budget_id=budget_id, account_id=account_id, created_by_user_id=user.id,
                        candidate_count=len(rows), candidates=rows, source_format=source_format)
    db.add(batch)
    db.flush()
    return batch


def get_staged_batch(db: Session, *, user: User, budget_id: str, batch_id: str) -> ImportBatch:
    # Scope ownership in SQL, before loading potentially private imported text.
    account_id = db.scalar(select(ImportBatch.account_id).where(ImportBatch.id == batch_id,
                      ImportBatch.budget_id == budget_id, ImportBatch.created_by_user_id == user.id))
    if account_id is None:
        raise HTTPException(status_code=404, detail="Import batch not found")
    _require_account(db, user, budget_id, account_id)
    return db.get(ImportBatch, batch_id)


def cancel_staged_batch(db: Session, *, user: User, budget_id: str, batch_id: str,
                        expected_version: int) -> ImportBatch:
    batch = get_staged_batch(db, user=user, budget_id=budget_id, batch_id=batch_id)
    if type(expected_version) is not int or expected_version < 0:
        raise HTTPException(status_code=422, detail="Invalid import version")
    changed = db.execute(update(ImportBatch).where(ImportBatch.id == batch.id,
                         ImportBatch.version == expected_version, ImportBatch.status == "review")
                         .values(status="cancelled", version=expected_version + 1)
                         .execution_options(synchronize_session=False))
    if changed.rowcount != 1:
        raise HTTPException(status_code=409, detail="Import review changed; refresh before continuing")
    db.refresh(batch)
    return batch
