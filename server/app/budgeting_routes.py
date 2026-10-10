from __future__ import annotations

import csv
import base64
import binascii
import json
from datetime import date, datetime, timezone, timedelta
import hashlib
import hmac
from io import StringIO
from typing import Optional
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Query, Request, status
from fastapi.responses import Response, StreamingResponse
from .schemas import MAX_INT64
from .calendar_dates import month_end
from .cash_rollover_repository import cash_rollover_effects
from .clock import today
from sqlalchemy import String, and_, cast, delete, false, func, or_, select
from sqlalchemy.orm import Session, selectinload
from sqlalchemy.exc import IntegrityError

from .access import (
    can_access_resource,
    find_visible_budget,
    has_budget_permission,
    has_capability,
    visible_resource_ids,
)
from .allocation import (
    PostingInput,
    append_operation,
    category_available_balance,
    lock_budget,
    ready_to_assign_balance,
    require_version,
)
from .database import get_db
from .debt_projection import (
    ProjectionTerms,
    StrategyDebt,
    monthly_strategy_payment,
    project_debt,
    project_debt_strategy,
    required_extra_payment_for_target,
)
from .debt_terms_history import debt_terms_snapshot
from .dependencies import get_current_user, get_settings
from .config import Settings
from .credit import add_payment_reserve_event, add_purchase_reserve_events, ensure_credit_payment_category
from .category_names import normalized_category_name
from .models import (
    Account,
    TransactionCreationReceipt,
    WorkspaceCommandReceipt,
    AccountRevision,
    AccountDebtTerms,
    AccountDebtTermsRevision,
    DebtPayoffPlan,
    DebtPayoffPlanRevision,
    AllowancePlan,
    AllowanceSplit,
    AllocationOperation,
    AllocationPosting,
    Budget,
    BudgetAccessProfile,
    BudgetPermission,
    BudgetStructureRevision,
    Category,
    CategoryFavorite,
    CategoryGroup,
    CategoryTarget,
    CategoryTargetRevision,
    CategoryTargetSnooze,
    CreditCardReserveEvent,
    DelegatedBudgetPolicy,
    DelegatedCategoryRule,
    Membership,
    Payee,
    ScheduledTransactionRevision,
    Reconciliation,
    ResourceGrant,
    Transaction,
    TransactionAttachment,
    TransactionChange,
    TransactionSplit,
    User,
)
from .payee_identity import resolve_or_create_payee
from .schemas import (
    AccountCreate,
    AccountUpdate,
    AccountBalanceResponse,
    AccountDebtTermsResponse,
    AccountDebtTermsRevisionResponse,
    AccountDebtTermsUpsert,
    DebtProjectionRequest,
    DebtProjectionResponse,
    DebtStrategyProjectionRequest,
    DebtStrategyProjectionResponse,
    DebtPayoffPlanUpsert,
    DebtPayoffPlanResponse,
    DebtPayoffPlanRevisionResponse,
    AccountResponse,
    AccountRevisionResponse,
    AllocationOperationResponse,
    AllocationOperationPageResponse,
    AllocationTransferCreate,
    AssignmentResponse,
    AssignmentUpsert,
    CategoryCreate,
    CategoryDelegationUpdate,
    CategoryFavoriteUpsert,
    CategoryUpdate,
    CategoryGroupCreate,
    CategoryGroupUpdate,
    CategoryGroupResponse,
    BudgetStructureRevisionResponse,
    OrderedIDsUpdate,
    CategoryMonthSummary,
    CategoryResponse,
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
    ReconciliationHistoryResponse,
    SmartFundingCommit,
    SmartFundingPreviewResponse,
    ScheduledTransactionResponse,
    TransactionBulkUpdateRequest,
    TransactionCreate,
    TransactionChangeResponse,
    TransactionDuplicateRequest,
    TransactionVoidRequest,
    TransactionScheduleRequest,
    TransactionAttachmentResponse,
    TransactionPageResponse,
    TransactionResponse,
    TransactionUpdate,
    TransferCreate,
    IdentifiedTransferCreate,
    TransferUpdate,
    TransferResponse,
    ReconciliationObservationResponse,
)
from .models import ScheduledTransaction
from .planning import next_occurrence
from .attachment_storage import AttachmentStorage, safe_filename, validate_content

ON_BUDGET_CASH_TYPES = {"checking", "savings", "cash"}
TRACKING_TYPES = {"loan", "mortgage", "asset", "tracking"}


def account_snapshot(account: Account) -> dict:
    return {
        "name": account.name,
        "account_type": account.account_type,
        "is_on_budget": account.is_on_budget,
        "is_closed": account.is_closed,
        "payment_category_id": account.payment_category_id,
    }


def category_group_snapshot(group: CategoryGroup) -> dict:
    return {"name": group.name, "sort_order": group.sort_order, "is_archived": group.is_archived}


def category_snapshot(category: Category) -> dict:
    return {
        "group_id": category.group_id, "name": category.name, "icon_name": category.icon_name,
        "note": category.note, "sort_order": category.sort_order, "is_archived": category.is_archived,
        "is_essential": category.is_essential, "is_emergency_fund": category.is_emergency_fund,
        "delegated_user_id": category.delegated_user_id,
    }


def append_structure_revision(db: Session, *, budget_id: str, resource_type: str,
                              resource_id: str, actor_user_id: str,
                              before: dict | None, after: dict) -> None:
    if before == after:
        return
    db.add(BudgetStructureRevision(
        budget_id=budget_id, resource_type=resource_type, resource_id=resource_id,
        action="created" if before is None else "updated", actor_user_id=actor_user_id,
        before_snapshot=before, after_snapshot=after,
    ))


def structure_revision_rows(db: Session, query) -> list[dict]:
    revisions = list(db.scalars(query))
    actor_ids = {item.actor_user_id for item in revisions}
    actors = {item.id: item.display_name for item in db.scalars(
        select(User).where(User.id.in_(actor_ids))
    )} if actor_ids else {}
    return [{
        "id": item.id, "resource_type": item.resource_type, "resource_id": item.resource_id,
        "action": item.action, "actor_user_id": item.actor_user_id,
        "actor_display_name": actors.get(item.actor_user_id),
        "before_snapshot": item.before_snapshot, "after_snapshot": item.after_snapshot,
        "created_at": item.created_at,
    } for item in revisions]


def debt_terms_readiness(terms: AccountDebtTerms) -> tuple[bool, list[str]]:
    common = ["annual_rate_basis_points", "rate_type", "payment_frequency", "due_day"]
    if terms.terms_type == "credit_card":
        required = common + ["minimum_payment_rule"]
        if terms.minimum_payment_rule in ("fixed", "greater_of"):
            required.append("minimum_payment_minor")
        if terms.minimum_payment_rule in ("percentage", "greater_of"):
            required.append("minimum_payment_rate_basis_points")
    else:
        required = common + ["scheduled_payment_minor"]
    missing = [name for name in required if getattr(terms, name) is None]
    return not missing, missing


def debt_terms_response(terms: AccountDebtTerms) -> dict:
    ready, missing = debt_terms_readiness(terms)
    return {
        column.key: getattr(terms, column.key)
        for column in AccountDebtTerms.__table__.columns
    } | {"projection_ready": ready, "missing_projection_fields": missing}


def projection_terms(terms: AccountDebtTerms) -> ProjectionTerms:
    return ProjectionTerms(
        annual_rate_basis_points=terms.annual_rate_basis_points,
        payment_frequency=terms.payment_frequency,
        scheduled_payment_minor=terms.scheduled_payment_minor,
        minimum_payment_rule=terms.minimum_payment_rule,
        minimum_payment_minor=terms.minimum_payment_minor,
        minimum_payment_rate_basis_points=terms.minimum_payment_rate_basis_points,
        promotional_rate_basis_points=terms.promotional_rate_basis_points,
        promotional_ends_on=terms.promotional_ends_on,
    )


def account_working_balance(db: Session, account_id: str) -> int:
    return account_working_balances(db, [account_id])[account_id]


def account_working_balances(db: Session, account_ids: list[str]) -> dict[str, int]:
    """Canonical posted balances, batched without transaction hydration."""
    balances = dict.fromkeys(account_ids, 0)
    if account_ids:
        for account_id, amount in db.execute(select(Transaction.account_id, func.sum(Transaction.amount_minor)).where(
            Transaction.account_id.in_(account_ids)
        ).group_by(Transaction.account_id)):
            balances[account_id] = int(amount or 0)
    return balances


def validate_account_treatment(account_type: str, is_on_budget: bool) -> None:
    valid = account_type in (ON_BUDGET_CASH_TYPES | {"credit"}) if is_on_budget else account_type in TRACKING_TYPES
    if not valid:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Choose a budget account type for On budget, or Loan/Mortgage/Asset/Tracking for Tracking.",
        )


def validate_account_type_transition(account: Account, account_type: str) -> None:
    if account_type == account.account_type:
        return
    if account.is_on_budget and account.account_type in ON_BUDGET_CASH_TYPES and account_type in ON_BUDGET_CASH_TYPES:
        return
    if not account.is_on_budget and account.account_type in TRACKING_TYPES and account_type in TRACKING_TYPES:
        return
    raise HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail="This account type change would reinterpret financial history. Create the appropriate account and transfer or reconcile explicitly instead.",
    )
from .planning import target_funding


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


def transaction_snapshot(transaction: Transaction) -> str:
    return json.dumps({
        "account_id": transaction.account_id,
        "category_id": transaction.category_id,
        "amount_minor": transaction.amount_minor,
        "occurred_on": transaction.occurred_on.isoformat(),
        "payee_name": transaction.payee_name,
        "payee_id": transaction.payee_id,
        "memo": transaction.memo,
        "financial_classification": transaction.financial_classification,
        "is_cleared": transaction.is_cleared,
        "is_reconciled": transaction.is_reconciled,
        "flag": transaction.flag,
        "tags": transaction.tags,
        "attachment_metadata": transaction.attachment_metadata,
        "status": transaction.status,
        "voided_at": transaction.voided_at.isoformat() if transaction.voided_at else None,
        "reversal_of_transaction_id": transaction.reversal_of_transaction_id,
        "reversal_transaction_id": transaction.reversal_transaction_id,
        "transfer_id": transaction.transfer_id,
        "splits": [{"category_id": item.category_id, "amount_minor": item.amount_minor, "memo": item.memo, "financial_classification": item.financial_classification} for item in transaction.splits],
    }, sort_keys=True, separators=(",", ":"))


def record_transaction_change(db: Session, transaction: Transaction, actor: User, action: str, *, before: str | None = None, after: str | None = None) -> None:
    db.add(TransactionChange(
        budget_id=transaction.budget_id,
        transaction_id=transaction.id,
        actor_user_id=actor.id,
        action=action,
        before_json=before,
        after_json=after,
    ))


def transaction_response_rows(db: Session, transactions: list[Transaction]) -> list[dict]:
    """Attach bounded, authorized actor provenance without exposing unrelated household activity."""
    if not transactions:
        return []
    ids = [item.id for item in transactions]
    ranked_changes = select(
        TransactionChange.transaction_id,
        TransactionChange.actor_user_id,
        TransactionChange.created_at,
        func.row_number().over(
            partition_by=TransactionChange.transaction_id,
            order_by=(TransactionChange.created_at.desc(), TransactionChange.id.desc()),
        ).label("position"),
    ).where(
        TransactionChange.transaction_id.in_(ids),
        TransactionChange.action.in_((
            "updated", "bulk_updated", "voided", "attachment_added", "attachment_detached",
        )),
    ).subquery()
    latest = {row.transaction_id: row for row in db.execute(select(
        ranked_changes.c.transaction_id, ranked_changes.c.actor_user_id, ranked_changes.c.created_at,
    ).where(ranked_changes.c.position == 1))}
    user_ids = {item.created_by_user_id for item in transactions}
    user_ids.update(change.actor_user_id for change in latest.values())
    names = {item.id: item.display_name for item in db.scalars(select(User).where(User.id.in_(user_ids)))}
    rows = []
    for item in transactions:
        row = TransactionResponse.model_validate(item).model_dump()
        row["created_by_display_name"] = names.get(item.created_by_user_id)
        if change := latest.get(item.id):
            row.update(
                last_modified_by_user_id=change.actor_user_id,
                last_modified_by_display_name=names.get(change.actor_user_id),
                last_modified_at=change.created_at,
            )
        rows.append(row)
    return rows


def require_budget(
    db: Session,
    user: User,
    budget_id: str,
    permission: BudgetPermission,
) -> Budget:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    if not has_budget_permission(db, user, budget, permission):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permission")
    return budget


def require_budget_capability(
    db: Session,
    user: User,
    budget_id: str,
    capability: str,
) -> Budget:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    if not has_capability(db, user, budget, capability):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient capability")
    return budget


@router.get("/accounts", response_model=list[AccountResponse])
def list_accounts(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Account | dict]:
    budget = require_budget_capability(db, user, budget_id, "view_accounts")
    query = select(Account).where(Account.budget_id == budget_id).order_by(Account.name)
    visible = visible_resource_ids(db, user, budget, "account")
    if visible is not None:
        query = query.where(Account.id.in_(visible))
    accounts = list(db.scalars(query))
    if has_capability(db, user, budget, "view_account_balances"):
        return accounts
    return [{
        "id": account.id,
        "budget_id": account.budget_id,
        "name": account.name,
        "account_type": account.account_type,
        "is_on_budget": account.is_on_budget,
        "is_closed": account.is_closed,
        "reconciled_balance_minor": None,
        "payment_category_id": (
            account.payment_category_id
            if account.payment_category_id is None or can_access_resource(
                db, user, budget, "category", account.payment_category_id
            )
            else None
        ),
    } for account in accounts]


def safe_csv_text(value: str) -> str:
    """Prevent spreadsheet programs from treating user-entered text as a formula."""
    return f"'{value}" if value.startswith(("=", "+", "-", "@")) else value


@router.get("/export.csv")
def export_budget_csv(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> StreamingResponse:
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    accounts = {
        item.id: item.name for item in db.scalars(select(Account).where(
            Account.budget_id == budget_id,
            *([Account.id.in_(visible_accounts)] if visible_accounts is not None else []),
        ))
    }
    categories = {
        item.id: item.name for item in db.scalars(select(Category).where(
            Category.budget_id == budget_id,
            *([Category.id.in_(visible_categories)] if visible_categories is not None else []),
        ))
    }
    transactions = list(db.scalars(
        select(Transaction)
        .options(selectinload(Transaction.splits))
        .where(Transaction.budget_id == budget_id)
        .order_by(Transaction.occurred_on, Transaction.created_at, Transaction.id)
    ))
    transactions = [item for item in transactions if (
        (visible_accounts is None or item.account_id in visible_accounts)
        and (
            visible_categories is None
            or item.category_id in visible_categories
            or (bool(item.splits) and all(split.category_id in visible_categories for split in item.splits))
        )
    )]
    output = StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow([
        "date", "account", "payee", "category", "amount_minor", "currency", "memo",
        "cleared", "reconciled", "transaction_id", "split_id",
    ])
    for transaction in transactions:
        rows = transaction.splits or [None]
        for split in rows:
            category_id = split.category_id if split else transaction.category_id
            writer.writerow([
                transaction.occurred_on.isoformat(),
                safe_csv_text(accounts.get(transaction.account_id, "")),
                safe_csv_text(transaction.payee_name),
                safe_csv_text(categories.get(category_id, "")),
                split.amount_minor if split else transaction.amount_minor,
                budget.currency_code,
                safe_csv_text(split.memo if split else transaction.memo),
                str(transaction.is_cleared).lower(),
                str(transaction.is_reconciled).lower(),
                transaction.id,
                split.id if split else "",
            ])
    return StreamingResponse(
        iter(["\ufeff", output.getvalue()]),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="budget-export.csv"'},
    )


@router.post("/accounts", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(
    budget_id: str,
    body: AccountCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    validate_account_treatment(body.account_type, body.is_on_budget)
    account_values = body.model_dump(exclude={"starting_balance_minor"})
    account = Account(budget_id=budget_id, **account_values)
    db.add(account)
    db.flush()
    if account.account_type == "credit":
        ensure_credit_payment_category(db, account)
    db.add(AccountRevision(
        budget_id=budget_id, account_id=account.id, action="created",
        actor_user_id=user.id, before_snapshot=None, after_snapshot=account_snapshot(account),
    ))
    if body.starting_balance_minor:
        db.add(Transaction(
            budget_id=budget_id,
            account_id=account.id,
            category_id=None,
            amount_minor=body.starting_balance_minor,
            occurred_on=today(),
            payee_name="Starting Balance",
            memo="Balance when account was added",
            is_cleared=True,
            created_by_user_id=user.id,
        ))
    db.commit()
    db.refresh(account)
    return account


@router.patch("/accounts/{account_id}", response_model=AccountResponse)
def update_account(
    budget_id: str,
    account_id: str,
    body: AccountUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    before = account_snapshot(account)
    validate_account_type_transition(account, body.account_type)
    account.name = body.name.strip()
    if not account.name:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="Enter an account name.")
    account.account_type = body.account_type
    if body.is_closed is not None:
        account.is_closed = body.is_closed
    if account.account_type == "credit" and account.payment_category_id:
        payment_category = db.get(Category, account.payment_category_id)
        if payment_category is not None and payment_category.system_type == "credit_payment":
            payment_category.name = f"{account.name} Payment"
            payment_category.name_key = normalized_category_name(payment_category.name)
    after = account_snapshot(account)
    if before == after:
        return account
    db.add(AccountRevision(
        budget_id=budget_id, account_id=account.id, action="updated",
        actor_user_id=user.id, before_snapshot=before, after_snapshot=after,
    ))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    db.refresh(account)
    return account


@router.get("/accounts/{account_id}/history", response_model=list[AccountRevisionResponse])
def account_history(
    budget_id: str,
    account_id: str,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_accounts")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    revisions = list(db.scalars(select(AccountRevision).where(
        AccountRevision.budget_id == budget_id,
        AccountRevision.account_id == account_id,
    ).order_by(AccountRevision.created_at.desc(), AccountRevision.id.desc()).offset(offset).limit(limit)))
    actor_ids = {item.actor_user_id for item in revisions}
    actors = {item.id: item.display_name for item in db.scalars(select(User).where(User.id.in_(actor_ids)))} if actor_ids else {}
    return [{
        "id": item.id, "account_id": item.account_id, "action": item.action,
        "actor_user_id": item.actor_user_id,
        "actor_display_name": actors.get(item.actor_user_id),
        "before_snapshot": item.before_snapshot, "after_snapshot": item.after_snapshot,
        "created_at": item.created_at,
    } for item in revisions]


@router.get("/accounts/{account_id}/debt-terms", response_model=Optional[AccountDebtTermsResponse])
def get_account_debt_terms(
    budget_id: str,
    account_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan", "mortgage"} or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    terms = db.get(AccountDebtTerms, account_id)
    return debt_terms_response(terms) if terms is not None else None


@router.put("/accounts/{account_id}/debt-terms", response_model=AccountDebtTermsResponse)
def upsert_account_debt_terms(
    budget_id: str,
    account_id: str,
    body: AccountDebtTermsUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "manage_budget_structure")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    expected_type = (
        "credit_card" if account.account_type == "credit"
        else "installment_loan" if account.account_type in {"loan", "mortgage"}
        else None
    )
    if expected_type is None:
        raise HTTPException(status_code=422, detail="Debt terms are available only for credit cards, loans, and mortgages")
    if body.terms_type != expected_type:
        raise HTTPException(status_code=422, detail=f"Use {expected_type} terms for this account")
    values = body.model_dump()
    terms = db.get(AccountDebtTerms, account_id)
    before = debt_terms_snapshot(terms) if terms is not None else None
    if terms is None:
        terms = AccountDebtTerms(account_id=account_id, budget_id=budget_id, **values)
        db.add(terms)
        db.flush()
    else:
        for name, value in values.items():
            setattr(terms, name, value)
        terms.updated_at = datetime.now(timezone.utc)
    after = debt_terms_snapshot(terms)
    if before == after:
        return debt_terms_response(terms)
    db.add(AccountDebtTermsRevision(
        budget_id=budget_id, account_id=account_id,
        action="created" if before is None else "updated", actor_user_id=user.id,
        before_snapshot=before, after_snapshot=after,
    ))
    db.commit()
    db.refresh(terms)
    return debt_terms_response(terms)


@router.delete("/accounts/{account_id}/debt-terms", status_code=status.HTTP_204_NO_CONTENT)
def delete_account_debt_terms(
    budget_id: str,
    account_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    budget = require_budget_capability(db, user, budget_id, "manage_budget_structure")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan", "mortgage"} or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    terms = db.get(AccountDebtTerms, account_id)
    if terms is not None:
        db.add(AccountDebtTermsRevision(
            budget_id=budget_id, account_id=account_id, action="deleted",
            actor_user_id=user.id, before_snapshot=debt_terms_snapshot(terms),
            after_snapshot=None,
        ))
        db.delete(terms)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/accounts/{account_id}/debt-terms/history",
    response_model=list[AccountDebtTermsRevisionResponse],
)
def account_debt_terms_history(
    budget_id: str,
    account_id: str,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan", "mortgage"} or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    revisions = list(db.scalars(select(AccountDebtTermsRevision).where(
        AccountDebtTermsRevision.budget_id == budget_id,
        AccountDebtTermsRevision.account_id == account_id,
    ).order_by(
        AccountDebtTermsRevision.created_at.desc(), AccountDebtTermsRevision.id.desc()
    ).offset(offset).limit(limit)))
    actor_ids = {item.actor_user_id for item in revisions}
    actors = {item.id: item.display_name for item in db.scalars(
        select(User).where(User.id.in_(actor_ids))
    )} if actor_ids else {}
    return [{
        "id": item.id, "account_id": item.account_id, "action": item.action,
        "actor_user_id": item.actor_user_id,
        "actor_display_name": actors.get(item.actor_user_id),
        "before_snapshot": item.before_snapshot, "after_snapshot": item.after_snapshot,
        "created_at": item.created_at,
    } for item in revisions]


@router.post("/accounts/{account_id}/debt-projection", response_model=DebtProjectionResponse)
def debt_projection(
    budget_id: str,
    account_id: str,
    body: DebtProjectionRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan", "mortgage"} or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    principal = max(-account_working_balance(db, account_id), 0)
    terms = db.get(AccountDebtTerms, account_id)
    if terms is None:
        missing = ["debt_terms"]
    else:
        _, missing = debt_terms_readiness(terms)
    base = {
        "account_id": account_id, "currency_code": budget.currency_code,
        "starting_principal_minor": principal, "extra_payment_minor": body.extra_payment_minor,
    }
    if missing:
        return base | {"status": "incomplete", "missing_projection_fields": missing}
    try:
        result = project_debt(
            principal, body.first_payment_on,
            projection_terms(terms),
            extra_payment_minor=body.extra_payment_minor,
        )
    except (ValueError, OverflowError) as error:
        raise HTTPException(status_code=422, detail="Projection inputs exceed the supported money or date range") from error
    return base | {
        "status": result.status, "missing_projection_fields": [], "payoff_date": result.payoff_date,
        "payment_count": result.payment_count, "projected_interest_minor": result.projected_interest_minor,
        "projected_total_cost_minor": result.projected_total_cost_minor,
        "points": [point.__dict__ for point in result.points],
    }


@router.post("/debt-strategy-projection", response_model=DebtStrategyProjectionResponse)
def debt_strategy_projection(
    budget_id: str,
    body: DebtStrategyProjectionRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Compare an explicit read-only strategy after applying resource visibility."""
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    visible = visible_resource_ids(db, user, budget, "account")
    budget_debt_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.account_type.in_(("credit", "loan", "mortgage")),
    )))
    requested_ids = set(body.account_ids) | set(body.custom_order)
    if any(value not in budget_debt_ids for value in requested_ids):
        raise HTTPException(status_code=404, detail="Projection resource not found")
    if visible is not None and any(value not in visible for value in requested_ids):
        raise HTTPException(status_code=404, detail="Projection resource not found")

    selected_ids = set(body.account_ids) if body.account_ids else budget_debt_ids
    if visible is not None:
        selected_ids &= visible
    accounts = list(db.scalars(select(Account).where(
        Account.id.in_(selected_ids)
    ).order_by(Account.name, Account.id))) if selected_ids else []
    if not accounts:
        raise HTTPException(status_code=422, detail="No visible debt accounts are available for projection")
    if body.strategy == "custom" and set(body.custom_order) != {item.id for item in accounts}:
        raise HTTPException(status_code=422, detail="Custom order must contain every selected account exactly once")

    strategy_debts: list[StrategyDebt] = []
    incomplete = []
    for account in accounts:
        principal = max(-account_working_balance(db, account.id), 0)
        terms = db.get(AccountDebtTerms, account.id)
        missing = ["debt_terms"] if terms is None else debt_terms_readiness(terms)[1]
        if missing:
            incomplete.append({"account_id": account.id, "missing_projection_fields": missing})
            continue
        resolved_terms = projection_terms(terms)
        strategy_debts.append(StrategyDebt(
            debt_id=account.id,
            principal_minor=principal,
            annual_rate_basis_points=terms.annual_rate_basis_points,
            promotional_rate_basis_points=terms.promotional_rate_basis_points,
            promotional_ends_on=terms.promotional_ends_on,
            planned_payment_minor=monthly_strategy_payment(
                resolved_terms, principal, body.first_payment_on
            ),
        ))
    base = {
        "currency_code": budget.currency_code,
        "strategy": body.strategy,
        "rollover": body.rollover,
        "extra_payment_minor": body.extra_payment_minor,
        "target_date": body.target_date,
    }
    if incomplete:
        return base | {"status": "incomplete", "incomplete_accounts": incomplete}
    try:
        result = project_debt_strategy(
            strategy_debts,
            body.first_payment_on,
            strategy=body.strategy,
            rollover=body.rollover,
            extra_payment_minor=body.extra_payment_minor,
            custom_order=body.custom_order,
        )
        required_extra = required_extra_payment_for_target(
            strategy_debts, body.first_payment_on, body.target_date,
            strategy=body.strategy, rollover=body.rollover,
            custom_order=body.custom_order,
        ) if body.target_date is not None else None
    except (ValueError, OverflowError) as error:
        raise HTTPException(status_code=422, detail="Projection inputs exceed the supported money or date range") from error
    return base | {
        "status": result.status,
        "payoff_order": list(result.payoff_order),
        "debt_free_date": result.debt_free_date,
        "payment_count": result.payment_count,
        "projected_interest_minor": result.projected_interest_minor,
        "projected_total_paid_minor": result.projected_total_paid_minor,
        "projected_total_cost_minor": result.projected_total_cost_minor,
        "accounts": [
            {
                "account_id": item.debt_id,
                "payoff_date": item.payoff_date,
                "payoff_month": item.payoff_month,
                "projected_interest_minor": item.projected_interest_minor,
                "projected_total_paid_minor": item.projected_total_paid_minor,
            }
            for item in result.debts
        ],
        "required_extra_payment_minor": required_extra,
        "on_target": (
            result.status == "paid_off" and result.debt_free_date is not None
            and result.debt_free_date <= body.target_date
        ) if body.target_date is not None else None,
    }


def _validated_payoff_plan_account_ids(
    db: Session, user: User, budget: Budget, account_ids: list[str], custom_order: list[str]
) -> None:
    requested = set(account_ids) | set(custom_order)
    if not requested:
        return
    debt_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget.id,
        Account.account_type.in_(("credit", "loan", "mortgage")),
    )))
    visible = visible_resource_ids(db, user, budget, "account")
    if any(value not in debt_ids for value in requested) or (
        visible is not None and any(value not in visible for value in requested)
    ):
        raise HTTPException(status_code=404, detail="Payoff plan resource not found")


@router.get("/debt-payoff-plan", response_model=Optional[DebtPayoffPlanResponse])
def get_debt_payoff_plan(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return this user's plan, removing accounts no longer visible to them."""
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    plan = db.scalar(select(DebtPayoffPlan).where(
        DebtPayoffPlan.budget_id == budget_id, DebtPayoffPlan.user_id == user.id
    ))
    if plan is None:
        return None
    visible = visible_resource_ids(db, user, budget, "account")
    debt_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.account_type.in_(("credit", "loan", "mortgage")),
    )))
    allowed = debt_ids if visible is None else debt_ids & visible
    account_ids = [value for value in plan.account_ids if value in allowed]
    custom_order = [value for value in plan.custom_order if value in allowed]
    strategy = plan.strategy
    if strategy == "custom" and set(custom_order) != set(account_ids):
        strategy, custom_order = "avalanche", []
    return {
        "id": plan.id, "budget_id": plan.budget_id, "user_id": plan.user_id,
        "strategy": strategy, "rollover": plan.rollover,
        "extra_payment_minor": plan.extra_payment_minor,
        "account_ids": account_ids, "custom_order": custom_order,
        "target_date": plan.target_date, "updated_at": plan.updated_at,
    }


@router.put("/debt-payoff-plan", response_model=DebtPayoffPlanResponse)
def upsert_debt_payoff_plan(
    budget_id: str,
    body: DebtPayoffPlanUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    _validated_payoff_plan_account_ids(db, user, budget, body.account_ids, body.custom_order)
    plan = db.scalar(select(DebtPayoffPlan).where(
        DebtPayoffPlan.budget_id == budget_id, DebtPayoffPlan.user_id == user.id
    ))
    values = body.model_dump()
    before = _payoff_plan_snapshot(plan) if plan is not None else None
    if plan is None:
        plan = DebtPayoffPlan(budget_id=budget_id, user_id=user.id, **values)
        db.add(plan)
    else:
        for name, value in values.items():
            setattr(plan, name, value)
        plan.updated_at = datetime.now(timezone.utc)
    after = _payoff_plan_snapshot(plan)
    if before != after:
        db.add(DebtPayoffPlanRevision(budget_id=budget_id, user_id=user.id,
            action="created" if before is None else "updated", before_snapshot=before, after_snapshot=after))
    db.commit()
    db.refresh(plan)
    return plan


@router.delete("/debt-payoff-plan", status_code=status.HTTP_204_NO_CONTENT)
def delete_debt_payoff_plan(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    require_budget_capability(db, user, budget_id, "manage_planning")
    plan = db.scalar(select(DebtPayoffPlan).where(
        DebtPayoffPlan.budget_id == budget_id, DebtPayoffPlan.user_id == user.id
    ))
    if plan is not None:
        db.add(DebtPayoffPlanRevision(budget_id=budget_id, user_id=user.id, action="deleted",
            before_snapshot=_payoff_plan_snapshot(plan), after_snapshot=None))
        db.delete(plan)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _payoff_plan_snapshot(plan: DebtPayoffPlan) -> dict:
    return {"strategy": plan.strategy, "rollover": plan.rollover, "extra_payment_minor": plan.extra_payment_minor,
            "account_ids": list(plan.account_ids), "custom_order": list(plan.custom_order),
            "target_date": plan.target_date.isoformat() if plan.target_date else None}


@router.get("/debt-payoff-plan/history", response_model=list[DebtPayoffPlanRevisionResponse])
def debt_payoff_plan_history(budget_id: str, limit: int = Query(50, ge=1, le=100), offset: int = Query(0, ge=0),
                            user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    scope = visible_resource_ids(db, user, budget, "account")
    debt_ids = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id,
        Account.account_type.in_(("credit", "loan", "mortgage")))))
    allowed = debt_ids if scope is None else debt_ids & scope
    def visible(snapshot):
        if snapshot is None:
            return None
        result = dict(snapshot)
        result["account_ids"] = [key for key in result["account_ids"] if key in allowed]
        result["custom_order"] = [key for key in result["custom_order"] if key in allowed]
        if result["strategy"] == "custom" and set(result["custom_order"]) != set(result["account_ids"]):
            result["strategy"], result["custom_order"] = "avalanche", []
        return result
    rows = db.scalars(select(DebtPayoffPlanRevision).where(DebtPayoffPlanRevision.budget_id == budget_id,
        DebtPayoffPlanRevision.user_id == user.id).order_by(DebtPayoffPlanRevision.created_at.desc(),
        DebtPayoffPlanRevision.id.desc()).offset(offset).limit(limit))
    return [{"id": row.id, "user_id": row.user_id, "action": row.action,
        "before_snapshot": visible(row.before_snapshot), "after_snapshot": visible(row.after_snapshot),
        "created_at": row.created_at} for row in rows]


@router.get("/accounts/{account_id}/balance", response_model=AccountBalanceResponse)
def account_balance(
    budget_id: str,
    account_id: str,
    through_date: Optional[date] = Query(default=None),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AccountBalanceResponse:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    conditions = [Transaction.account_id == account_id]
    if through_date is not None:
        conditions.append(Transaction.occurred_on <= through_date)
    cleared = int(db.scalar(select(
        func.coalesce(func.sum(Transaction.amount_minor), 0)
    ).where(*conditions, Transaction.is_cleared.is_(True))) or 0)
    uncleared = int(db.scalar(select(
        func.coalesce(func.sum(Transaction.amount_minor), 0)
    ).where(*conditions, Transaction.is_cleared.is_(False))) or 0)
    return AccountBalanceResponse(
        account_id=account.id,
        currency_code=budget.currency_code,
        cleared_balance_minor=cleared,
        uncleared_balance_minor=uncleared,
        working_balance_minor=cleared + uncleared,
        reconciled_balance_minor=account.reconciled_balance_minor,
        through_date=through_date,
    )


@router.get("/category-groups", response_model=list[CategoryGroupResponse])
def list_category_groups(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[CategoryGroup]:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    visible = visible_resource_ids(db, user, budget, "category")
    query = select(CategoryGroup).where(CategoryGroup.budget_id == budget_id)
    if visible is not None:
        query = query.where(CategoryGroup.id.in_(select(Category.group_id).where(Category.id.in_(visible))))
    return list(db.scalars(query.order_by(CategoryGroup.sort_order, CategoryGroup.name)))


@router.post("/category-groups", response_model=CategoryGroupResponse, status_code=status.HTTP_201_CREATED)
def create_category_group(
    budget_id: str,
    body: CategoryGroupCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CategoryGroup:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    group = CategoryGroup(budget_id=budget_id, **body.model_dump())
    db.add(group)
    db.flush()
    append_structure_revision(db, budget_id=budget_id, resource_type="category_group",
                              resource_id=group.id, actor_user_id=user.id,
                              before=None, after=category_group_snapshot(group))
    db.commit()
    db.refresh(group)
    return group


@router.put("/category-group-order", response_model=list[CategoryGroupResponse])
def reorder_category_groups(
    budget_id: str, body: OrderedIDsUpdate, user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[CategoryGroup]:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    groups = list(db.scalars(select(CategoryGroup).where(
        CategoryGroup.budget_id == budget_id, CategoryGroup.is_archived.is_(False)
    )))
    by_id = {item.id: item for item in groups}
    if len(body.ordered_ids) != len(set(body.ordered_ids)) or set(body.ordered_ids) != set(by_id):
        raise HTTPException(status_code=422, detail="Order must contain every active category group exactly once")
    for index, item_id in enumerate(body.ordered_ids):
        group = by_id[item_id]
        before = category_group_snapshot(group)
        group.sort_order = index * 10
        append_structure_revision(db, budget_id=budget_id, resource_type="category_group",
                                  resource_id=group.id, actor_user_id=user.id,
                                  before=before, after=category_group_snapshot(group))
    db.commit()
    return [by_id[item_id] for item_id in body.ordered_ids]


@router.put("/category-groups/{group_id}", response_model=CategoryGroupResponse)
def update_category_group(budget_id: str, group_id: str, body: CategoryGroupUpdate, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> CategoryGroup:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    group = db.get(CategoryGroup, group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=404, detail="Category group not found")
    before = category_group_snapshot(group)
    group.name = body.name.strip(); group.sort_order = body.sort_order; group.is_archived = body.is_archived
    append_structure_revision(db, budget_id=budget_id, resource_type="category_group",
                              resource_id=group.id, actor_user_id=user.id,
                              before=before, after=category_group_snapshot(group))
    db.commit(); db.refresh(group); return group


@router.get("/category-groups/{group_id}/history", response_model=list[BudgetStructureRevisionResponse])
def category_group_history(
    budget_id: str, group_id: str, limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0), user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    group = db.get(CategoryGroup, group_id)
    visible = visible_resource_ids(db, user, budget, "category")
    if group is None or group.budget_id != budget_id or (
        visible is not None and db.scalar(select(Category.id).where(
            Category.group_id == group_id, Category.id.in_(visible)
        ).limit(1)) is None
    ):
        raise HTTPException(status_code=404, detail="Category group not found")
    return structure_revision_rows(db, select(BudgetStructureRevision).where(
        BudgetStructureRevision.budget_id == budget_id,
        BudgetStructureRevision.resource_type == "category_group",
        BudgetStructureRevision.resource_id == group_id,
    ).order_by(BudgetStructureRevision.created_at.desc(), BudgetStructureRevision.id.desc())
      .offset(offset).limit(limit))


@router.delete("/category-groups/{group_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_category_group(budget_id: str, group_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> None:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    group = db.get(CategoryGroup, group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=404, detail="Category group not found")
    if db.scalar(select(Category.id).where(Category.group_id == group_id).limit(1)) is not None:
        raise HTTPException(status_code=409, detail="Move or archive every category before deleting this group")
    db.delete(group); db.commit()


@router.get("/categories", response_model=list[CategoryResponse])
def list_categories(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Category | dict]:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    query = select(Category).where(Category.budget_id == budget_id)
    visible = visible_resource_ids(db, user, budget, "category")
    if visible is not None:
        query = query.where(Category.id.in_(visible))
    categories = list(db.scalars(query.order_by(Category.group_id, Category.sort_order, Category.name)))
    favorite_orders = dict(db.execute(select(
        CategoryFavorite.category_id, CategoryFavorite.sort_order
    ).where(
        CategoryFavorite.budget_id == budget_id,
        CategoryFavorite.user_id == user.id,
        CategoryFavorite.category_id.in_([category.id for category in categories]),
    )).all()) if categories else {}
    return [{
        "id": category.id,
        "budget_id": category.budget_id,
        "group_id": category.group_id,
        "name": category.name,
        "icon_name": category.icon_name,
        "note": category.note,
        "sort_order": category.sort_order,
        "is_archived": category.is_archived,
        "is_essential": category.is_essential,
        "is_emergency_fund": category.is_emergency_fund,
        "system_type": category.system_type,
        "linked_account_id": (
            category.linked_account_id
            if category.linked_account_id is None or can_access_resource(
                db, user, budget, "account", category.linked_account_id
            )
            else None
        ),
        "delegated_user_id": category.delegated_user_id,
        "is_favorite": category.id in favorite_orders,
        "favorite_sort_order": favorite_orders.get(category.id),
    } for category in categories]


@router.put("/category-order/{group_id}", response_model=list[CategoryResponse])
def reorder_categories(
    budget_id: str, group_id: str, body: OrderedIDsUpdate,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> list[Category]:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    group = db.get(CategoryGroup, group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=404, detail="Category group not found")
    categories = list(db.scalars(select(Category).where(
        Category.budget_id == budget_id, Category.group_id == group_id,
    )))
    by_id = {item.id: item for item in categories}
    if len(body.ordered_ids) != len(set(body.ordered_ids)) or set(body.ordered_ids) != set(by_id):
        raise HTTPException(status_code=422, detail="Order must contain every category in the group exactly once")
    for index, item_id in enumerate(body.ordered_ids):
        category = by_id[item_id]
        before = category_snapshot(category)
        category.sort_order = index * 10
        append_structure_revision(db, budget_id=budget_id, resource_type="category",
                                  resource_id=category.id, actor_user_id=user.id,
                                  before=before, after=category_snapshot(category))
    db.commit()
    return [by_id[item_id] for item_id in body.ordered_ids]


@router.put("/categories/{category_id}/favorite", response_model=CategoryResponse)
def favorite_category(
    budget_id: str,
    category_id: str,
    body: CategoryFavoriteUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or not can_access_resource(db, user, budget, "category", category_id):
        raise HTTPException(status_code=404, detail="Category not found")
    favorite = db.scalar(select(CategoryFavorite).where(
        CategoryFavorite.user_id == user.id,
        CategoryFavorite.category_id == category_id,
    ))
    if favorite is None:
        favorite = CategoryFavorite(
            budget_id=budget_id, user_id=user.id, category_id=category_id, sort_order=body.sort_order
        )
        db.add(favorite)
    else:
        favorite.sort_order = body.sort_order
    db.commit()
    return {
        "id": category.id, "budget_id": category.budget_id, "group_id": category.group_id,
        "name": category.name, "icon_name": category.icon_name, "note": category.note,
        "sort_order": category.sort_order, "is_archived": category.is_archived,
        "is_essential": category.is_essential, "is_emergency_fund": category.is_emergency_fund,
        "system_type": category.system_type, "linked_account_id": (
            category.linked_account_id
            if category.linked_account_id is None or can_access_resource(
                db, user, budget, "account", category.linked_account_id
            )
            else None
        ),
        "delegated_user_id": category.delegated_user_id, "is_favorite": True,
        "favorite_sort_order": favorite.sort_order,
    }


@router.delete("/categories/{category_id}/favorite", status_code=status.HTTP_204_NO_CONTENT)
def unfavorite_category(
    budget_id: str,
    category_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or not can_access_resource(db, user, budget, "category", category_id):
        raise HTTPException(status_code=404, detail="Category not found")
    favorite = db.scalar(select(CategoryFavorite).where(
        CategoryFavorite.user_id == user.id,
        CategoryFavorite.category_id == category_id,
    ))
    if favorite is not None:
        db.delete(favorite)
        db.commit()


@router.post("/categories", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
def create_category(
    budget_id: str,
    body: CategoryCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Category:
    try:
        budget = require_budget_capability(db, user, budget_id, "manage_budget_structure")
        is_own_delegated_creation = False
    except HTTPException:
        budget = require_budget_capability(db, user, budget_id, "manage_own_categories")
        is_own_delegated_creation = True
    group = db.get(CategoryGroup, body.group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=422, detail="Invalid category group")
    if is_own_delegated_creation and body.delegated_user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Delegated members may only create categories in their own budget",
        )
    if is_own_delegated_creation:
        policy = db.scalar(select(DelegatedBudgetPolicy).where(
            DelegatedBudgetPolicy.budget_id == budget_id,
            DelegatedBudgetPolicy.user_id == user.id,
        ))
        if policy is None or not policy.allow_category_creation:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Category creation is disabled for this delegated budget")
    if body.delegated_user_id is not None:
        member = db.scalar(select(Membership).where(
            Membership.household_id == budget.household_id,
            Membership.user_id == body.delegated_user_id,
            Membership.is_active.is_(True),
        ))
        if member is None:
            raise HTTPException(status_code=422, detail="Delegated user must be an active household member")
    category_name = body.name.strip()
    name_key = normalized_category_name(category_name)
    if not name_key:
        raise HTTPException(status_code=422, detail="Enter a category name")
    existing_names = db.scalars(select(Category.name).where(Category.group_id == body.group_id)).all()
    if any(normalized_category_name(name) == name_key for name in existing_names):
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    category_values = body.model_dump(exclude={"name"})
    category = Category(budget_id=budget_id, name=category_name, name_key=name_key, **category_values)
    try:
        db.add(category)
        db.flush()
        append_structure_revision(db, budget_id=budget_id, resource_type="category",
                                  resource_id=category.id, actor_user_id=user.id,
                                  before=None, after=category_snapshot(category))
        if is_own_delegated_creation:
            profile = db.scalar(select(BudgetAccessProfile).where(
                BudgetAccessProfile.budget_id == budget_id,
                BudgetAccessProfile.user_id == user.id,
            ))
            if profile is not None and profile.restrict_categories:
                db.add(ResourceGrant(
                    budget_id=budget_id,
                    user_id=user.id,
                    resource_type="category",
                    resource_id=category.id,
                ))
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    db.refresh(category)
    return category


@router.put("/categories/{category_id}/delegation", response_model=CategoryResponse)
def update_category_delegation(
    budget_id: str,
    category_id: str,
    body: CategoryDelegationUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Category:
    budget = require_budget_capability(db, user, budget_id, "manage_allowances")
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or category.system_type is not None:
        raise HTTPException(status_code=404, detail="Category not found")
    if body.delegated_user_id is not None:
        member = db.scalar(select(Membership).where(
            Membership.household_id == budget.household_id,
            Membership.user_id == body.delegated_user_id,
            Membership.is_active.is_(True),
        ))
        if member is None:
            raise HTTPException(status_code=422, detail="Delegated user must be an active household member")
    active_plan = db.scalar(select(AllowancePlan.id).join(
        AllowanceSplit, AllowanceSplit.plan_id == AllowancePlan.id
    ).where(
        AllowanceSplit.destination_category_id == category_id,
        AllowancePlan.is_active.is_(True),
    ))
    if active_plan is not None and body.delegated_user_id != category.delegated_user_id:
        raise HTTPException(status_code=409, detail="Deactivate the category's allowance plan first")
    before = category_snapshot(category)
    category.delegated_user_id = body.delegated_user_id
    append_structure_revision(db, budget_id=budget_id, resource_type="category",
                              resource_id=category.id, actor_user_id=user.id,
                              before=before, after=category_snapshot(category))
    db.commit()
    db.refresh(category)
    return category


@router.put("/categories/{category_id}", response_model=CategoryResponse)
def update_category(
    budget_id: str,
    category_id: str,
    body: CategoryUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Category:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or category.system_type is not None or not can_access_resource(db, user, budget, "category", category_id):
        raise HTTPException(status_code=404, detail="Category not found")
    may_manage_all = has_capability(db, user, budget, "manage_budget_structure")
    may_manage_own = has_capability(db, user, budget, "manage_own_categories") and category.delegated_user_id == user.id
    if not may_manage_all and not may_manage_own:
        raise HTTPException(status_code=403, detail="You may only manage categories in your delegated budget")
    before = category_snapshot(category)
    group = db.get(CategoryGroup, body.group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=422, detail="Invalid category group")
    category_name = body.name.strip()
    name_key = normalized_category_name(category_name)
    if not name_key:
        raise HTTPException(status_code=422, detail="Enter a category name")
    sibling_rows = db.execute(select(Category.id, Category.name).where(
        Category.group_id == body.group_id,
        Category.id != category_id,
    )).all()
    conflicting_siblings = [row for row in sibling_rows if normalized_category_name(row.name) == name_key]
    current_key = normalized_category_name(category.name)
    if conflicting_siblings and name_key != current_key:
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    category.group_id = body.group_id
    category.name = category_name
    category.name_key = None if conflicting_siblings else name_key
    category.icon_name = body.icon_name or None
    category.note = body.note
    category.sort_order = body.sort_order
    category.is_archived = body.is_archived
    if body.is_essential is not None:
        category.is_essential = body.is_essential
    if body.is_emergency_fund is not None:
        category.is_emergency_fund = body.is_emergency_fund
    append_structure_revision(db, budget_id=budget_id, resource_type="category",
                              resource_id=category.id, actor_user_id=user.id,
                              before=before, after=category_snapshot(category))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    db.refresh(category)
    return category


@router.get("/categories/{category_id}/history", response_model=list[BudgetStructureRevisionResponse])
def category_history(
    budget_id: str, category_id: str, limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0), user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or not can_access_resource(
        db, user, budget, "category", category_id
    ):
        raise HTTPException(status_code=404, detail="Category not found")
    return structure_revision_rows(db, select(BudgetStructureRevision).where(
        BudgetStructureRevision.budget_id == budget_id,
        BudgetStructureRevision.resource_type == "category",
        BudgetStructureRevision.resource_id == category_id,
    ).order_by(BudgetStructureRevision.created_at.desc(), BudgetStructureRevision.id.desc())
      .offset(offset).limit(limit))


@router.delete("/categories/{category_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_category(budget_id: str, category_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> None:
    budget = require_budget_capability(db, user, budget_id, "manage_budget_structure")
    category = db.get(Category, category_id)
    if (
        category is None or category.budget_id != budget_id or category.system_type is not None
        or not can_access_resource(db, user, budget, "category", category_id)
    ):
        raise HTTPException(status_code=404, detail="Category not found")
    linked = any((
        db.scalar(select(Transaction.id).where(Transaction.category_id == category_id).limit(1)),
        db.scalar(select(TransactionSplit.id).where(TransactionSplit.category_id == category_id).limit(1)),
        db.scalar(select(AllocationPosting.id).where(AllocationPosting.category_id == category_id).limit(1)),
        db.scalar(select(CategoryTarget.id).where(CategoryTarget.category_id == category_id).limit(1)),
        db.scalar(select(CategoryTargetRevision.id).where(CategoryTargetRevision.category_id == category_id).limit(1)),
        db.scalar(select(ScheduledTransactionRevision.id).where(or_(
            ScheduledTransactionRevision.category_id == category_id,
            ScheduledTransactionRevision.before_category_id == category_id,
        )).limit(1)),
    ))
    if linked:
        raise HTTPException(status_code=409, detail="This category has financial history. Archive it to preserve the audit trail")
    db.delete(category); db.commit()


@router.put("/categories/{category_id}/assignment", response_model=AssignmentResponse)
def upsert_assignment(
    budget_id: str,
    category_id: str,
    body: AssignmentUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    access_budget = require_budget_capability(db, user, budget_id, "assign_money")
    delegated_policy = db.scalar(select(DelegatedBudgetPolicy.id).where(
        DelegatedBudgetPolicy.budget_id == budget_id,
        DelegatedBudgetPolicy.user_id == user.id,
    ))
    if delegated_policy is not None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Delegated members must allocate from their scoped pool using money moves",
        )
    category = db.get(Category, category_id)
    if (
        category is None
        or category.budget_id != budget_id
        or not can_access_resource(db, user, access_budget, "category", category_id)
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Category not found")
    # Planning periods may be in the future, unlike actual transaction dates. The
    # all-date RTA guard below reserves only existing cash, never forecast income.
    budget = lock_budget(db, budget_id)
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "assignment", "category_id": category_id,
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) if operation_id is not None else None
    if receipt is not None and (receipt.command_kind != "assignment" or receipt.resource_id != category_id or receipt.request_digest != digest):
        raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
    if receipt is None:
        require_version(budget, body.expected_allocation_version)
    through = month_end(body.month)
    current_assigned = int(db.scalar(
        select(func.coalesce(func.sum(AllocationPosting.amount_minor), 0))
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(
            AllocationPosting.budget_id == budget_id,
            AllocationPosting.category_id == category_id,
            AllocationOperation.occurred_on >= body.month,
            AllocationOperation.occurred_on <= through,
        )
    ) or 0)
    if receipt is not None:
        return {"budget_id": budget_id, "category_id": category_id, "month": body.month,
                "assigned_minor": current_assigned, "allocation_version": budget.allocation_version}
    delta = body.assigned_minor - current_assigned
    if not -(2**63) + 1 <= delta <= 2**63 - 1:
        raise HTTPException(status_code=422, detail="Allocation change is outside the supported range")
    if delta > 0 and ready_to_assign_balance(db, budget_id) < delta:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Not enough real money to assign")
    if delta != 0:
        append_operation(
            db,
            budget=budget,
            actor=user,
            occurred_on=body.month,
            kind="assignment",
            note=f"Set {category.name} allocation for {body.month.isoformat()}",
            postings=[
                PostingInput(bucket="ready_to_assign", amount_minor=-delta),
                PostingInput(bucket="category", category_id=category_id, amount_minor=delta),
            ],
        )
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="assignment", resource_id=category_id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return upsert_assignment(budget_id, category_id, body, user, db)
    return {
        "budget_id": budget_id,
        "category_id": category_id,
        "month": body.month,
        "assigned_minor": body.assigned_minor,
        "allocation_version": budget.allocation_version,
    }


def _visible_allocation_operations_query(db: Session, user: User, budget: Budget):
    """Apply whole-operation privacy before any history pagination."""
    query = (
        select(AllocationOperation)
        .options(selectinload(AllocationOperation.postings))
        .where(AllocationOperation.budget_id == budget.id)
        .order_by(AllocationOperation.occurred_on.desc(), AllocationOperation.created_at.desc(), AllocationOperation.id)
    )
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_categories is not None:
        if not visible_categories:
            return query.where(false())
        # Filter whole operations in SQL before loading notes, actors or counterpart postings.
        # Returning just the visible leg would leak private transfers and break balanced history.
        visible_posting = select(AllocationPosting.id).where(
            AllocationPosting.operation_id == AllocationOperation.id,
            AllocationPosting.category_id.in_(visible_categories),
        ).exists()
        hidden_posting = select(AllocationPosting.id).where(
            AllocationPosting.operation_id == AllocationOperation.id,
            AllocationPosting.category_id.is_not(None),
            AllocationPosting.category_id.not_in(visible_categories),
        ).exists()
        query = query.where(visible_posting, ~hidden_posting)
    return query


def _allocation_operation_rows(db: Session, budget: Budget, operations: list[AllocationOperation]) -> list[dict]:
    actor_ids = {operation.actor_user_id for operation in operations}
    actor_names = {
        actor.id: actor.display_name
        for actor in db.scalars(select(User).where(User.id.in_(actor_ids)))
    } if actor_ids else {}
    return [{
        "id": operation.id,
        "budget_id": operation.budget_id,
        "occurred_on": operation.occurred_on,
        "kind": operation.kind,
        "actor_user_id": operation.actor_user_id,
        "actor_display_name": actor_names.get(operation.actor_user_id),
        "note": operation.note,
        "source": operation.source,
        "allocation_version": budget.allocation_version,
        "postings": operation.postings,
    } for operation in operations]


@router.get("/allocations/page", response_model=AllocationOperationPageResponse)
def list_allocation_operations_page(
    budget_id: str,
    limit: int = Query(default=50, ge=1, le=100),
    cursor: Optional[str] = Query(default=None),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "view_allocation_history")
    query = _visible_allocation_operations_query(db, user, budget)
    if cursor:
        try:
            padding = "=" * (-len(cursor) % 4)
            decoded = json.loads(base64.urlsafe_b64decode(cursor + padding).decode("utf-8"))
            cursor_date = date.fromisoformat(decoded["date"])
            cursor_created = datetime.fromisoformat(decoded["created"])
            cursor_id = str(decoded["id"])
            if decoded.get("v") != 1 or not cursor_id:
                raise ValueError
        except (binascii.Error, KeyError, TypeError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
            raise HTTPException(status_code=422, detail="Invalid allocation history cursor")
        query = query.where(or_(
            AllocationOperation.occurred_on < cursor_date,
            and_(AllocationOperation.occurred_on == cursor_date, AllocationOperation.created_at < cursor_created),
            and_(AllocationOperation.occurred_on == cursor_date, AllocationOperation.created_at == cursor_created,
                 AllocationOperation.id > cursor_id),
        ))
    operations = list(db.scalars(query.limit(limit + 1)))
    has_more = len(operations) > limit
    page = operations[:limit]
    next_cursor = None
    if has_more:
        last = page[-1]
        payload = json.dumps({
            "v": 1, "date": last.occurred_on.isoformat(),
            "created": last.created_at.isoformat(), "id": last.id,
        }, separators=(",", ":"))
        next_cursor = base64.urlsafe_b64encode(payload.encode("utf-8")).decode("ascii").rstrip("=")
    return {
        "items": _allocation_operation_rows(db, budget, page),
        "next_cursor": next_cursor,
    }


@router.get("/allocations", response_model=list[AllocationOperationResponse])
def list_allocation_operations(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    """Backward-compatible unpaged contract for older clients."""
    budget = require_budget_capability(db, user, budget_id, "view_allocation_history")
    operations = list(db.scalars(_visible_allocation_operations_query(db, user, budget)))
    return _allocation_operation_rows(db, budget, operations)


@router.post(
    "/allocation-transfers",
    response_model=AllocationOperationResponse,
    status_code=status.HTTP_201_CREATED,
)
def transfer_allocation(
    budget_id: str,
    body: AllocationTransferCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    access_budget = require_budget_capability(db, user, budget_id, "move_money")
    if body.occurred_on > today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
    budget = lock_budget(db, budget_id)
    transfer_categories = [db.get(Category, category_id) for category_id in (
        body.source_category_id, body.destination_category_id
    )]
    if any(
        category is None or category.budget_id != budget_id or category.is_archived
        for category in transfer_categories
    ):
        raise HTTPException(status_code=422, detail="Invalid allocation category")
    if any(not can_access_resource(db, user, access_budget, "category", category.id) for category in transfer_categories):
        raise HTTPException(status_code=404, detail="Allocation category not found")
    delegated_policy = db.scalar(select(DelegatedBudgetPolicy).where(
        DelegatedBudgetPolicy.budget_id == budget_id,
        DelegatedBudgetPolicy.user_id == user.id,
    ))
    if delegated_policy is not None:
        if not delegated_policy.allow_reallocation:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Reallocation is disabled for this delegated budget")
        if any(category.delegated_user_id != user.id for category in transfer_categories):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Delegated money may only move within your budget")
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "allocation_transfer", "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "allocation_transfer" or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            accepted = db.scalar(select(AllocationOperation).options(selectinload(AllocationOperation.postings)).where(
                AllocationOperation.id == receipt.resource_id, AllocationOperation.budget_id == budget_id,
            ))
            if accepted is None:
                raise HTTPException(status_code=404, detail="Allocation operation not found")
            return _allocation_operation_rows(db, budget, [accepted])[0]
    require_version(budget, body.expected_allocation_version)
    if delegated_policy is not None:
        rules = {
            rule.category_id: rule for rule in db.scalars(select(DelegatedCategoryRule).where(
                DelegatedCategoryRule.policy_id == delegated_policy.id,
                DelegatedCategoryRule.category_id.in_([category.id for category in transfer_categories]),
            ))
        }
        source_rule = rules.get(body.source_category_id)
        destination_rule = rules.get(body.destination_category_id)
        source_after = category_available_balance(db, budget_id, body.source_category_id, through=body.occurred_on) - body.amount_minor
        destination_after = category_available_balance(db, budget_id, body.destination_category_id, through=body.occurred_on) + body.amount_minor
        if source_rule is not None and source_rule.rule_kind == "approval_gated":
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Withdrawing from this category requires approval")
        if source_rule is not None and source_rule.rule_kind == "hard_limit" and source_rule.minimum_minor is not None and source_after < source_rule.minimum_minor:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"Category must retain at least {source_rule.minimum_minor} minor units")
        if destination_rule is not None and destination_rule.rule_kind == "hard_limit" and destination_rule.maximum_minor is not None and destination_after > destination_rule.maximum_minor:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"Category cannot exceed {destination_rule.maximum_minor} minor units")
    if category_available_balance(
        db, budget_id, body.source_category_id, through=body.occurred_on
    ) < body.amount_minor:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Source category has insufficient funds")
    operation = append_operation(
        db,
        budget=budget,
        actor=user,
        occurred_on=body.occurred_on,
        kind="category_transfer",
        note=body.note,
        postings=[
            PostingInput(
                bucket="category",
                category_id=body.source_category_id,
                amount_minor=-body.amount_minor,
            ),
            PostingInput(
                bucket="category",
                category_id=body.destination_category_id,
                amount_minor=body.amount_minor,
            ),
        ],
    )
    if operation_id is not None:
        db.flush() # Materialize the accepted allocation operation's generated identity.
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="allocation_transfer", resource_id=operation.id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return transfer_allocation(budget_id, body, user, db)
    db.refresh(operation)
    return {
        "id": operation.id,
        "budget_id": operation.budget_id,
        "occurred_on": operation.occurred_on,
        "kind": operation.kind,
        "actor_user_id": operation.actor_user_id,
        "note": operation.note,
        "source": operation.source,
        "allocation_version": budget.allocation_version,
        "postings": operation.postings,
    }


def transaction_visibility_conditions(db: Session, user: User, budget: Budget) -> list:
    """SQL privacy boundary shared by browsing and import observation retrieval."""
    conditions = [Transaction.budget_id == budget.id]
    accounts = visible_resource_ids(db, user, budget, "account")
    categories = visible_resource_ids(db, user, budget, "category")
    if accounts is not None:
        conditions.append(Transaction.account_id.in_(accounts) if accounts else false())
    if categories is not None:
        conditions.append(or_(
            Transaction.category_id.in_(categories),
            and_(Transaction.category_id.is_(None), Transaction.splits.any(),
                 ~Transaction.splits.any(~TransactionSplit.category_id.in_(categories))),
        ) if categories else false())
    return conditions


def _visible_transactions(db: Session, user: User, budget: Budget) -> list[Transaction]:
    transactions = list(db.scalars(select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget.id
    ).order_by(Transaction.occurred_on.desc(), Transaction.created_at.desc())))
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    return [item for item in transactions if (
        (visible_accounts is None or item.account_id in visible_accounts)
        and (
            visible_categories is None
            or item.category_id in visible_categories
            or (bool(item.splits) and all(split.category_id in visible_categories for split in item.splits))
        )
    )]


def _can_access_transaction_resources(
    db: Session, user: User, budget: Budget, transaction: Transaction,
) -> bool:
    """Apply the same account/category boundary to every transaction surface.

    A category-restricted member cannot see an uncategorized row. This matters
    for mutation/detail endpoints as much as it does for lists: knowing an ID
    must never turn a hidden row into an editable resource.
    """
    if not can_access_resource(db, user, budget, "account", transaction.account_id):
        return False
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_categories is None:
        return True
    if transaction.category_id is not None:
        return transaction.category_id in visible_categories
    if transaction.splits:
        return all(split.category_id in visible_categories for split in transaction.splits)
    return False


@router.get("/transactions/search", response_model=TransactionPageResponse)
def search_transactions(
    budget_id: str,
    q: str = Query(default="", max_length=150),
    account_id: list[str] = Query(default=[]),
    category_id: list[str] = Query(default=[]),
    payee_id: list[str] = Query(default=[]),
    start_date: Optional[date] = None,
    end_date: Optional[date] = None,
    minimum_amount_minor: Optional[int] = None,
    maximum_amount_minor: Optional[int] = None,
    transaction_type: Optional[str] = Query(default=None, pattern="^(income|spending|refund|transfer|interest_charge)$"),
    lifecycle_status: list[str] = Query(default=[]),
    cleared: Optional[bool] = None,
    reconciled: Optional[bool] = None,
    flag: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
    actor_user_id: list[str] = Query(default=[]),
    is_transfer: Optional[bool] = None,
    is_scheduled_realization: Optional[bool] = None,
    sort: str = Query(default="date_desc", pattern="^(date_desc|date_asc|amount_desc|amount_asc|payee_asc)$"),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: Optional[str] = Query(default=None, max_length=200),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransactionPageResponse:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    if start_date is not None and end_date is not None and start_date > end_date:
        raise HTTPException(status_code=422, detail="start_date must be on or before end_date")
    if any(value not in {"posted", "voided", "reversal"} for value in lifecycle_status):
        raise HTTPException(status_code=422, detail="Invalid transaction lifecycle status")

    search_text = q.strip().casefold()

    conditions = transaction_visibility_conditions(db, user, budget)
    if search_text:
        pattern = f"%{search_text}%"
        conditions.append(or_(
            func.lower(Transaction.payee_name).like(pattern),
            func.lower(Transaction.memo).like(pattern),
            func.lower(func.coalesce(Transaction.flag, "")).like(pattern),
            func.lower(cast(Transaction.tags, String)).like(pattern),
        ))
    if account_id:
        conditions.append(Transaction.account_id.in_(account_id))
    if category_id:
        conditions.append(or_(
            Transaction.category_id.in_(category_id),
            Transaction.splits.any(TransactionSplit.category_id.in_(category_id)),
        ))
    if payee_id:
        conditions.append(Transaction.payee_id.in_(payee_id))
    if start_date is not None:
        conditions.append(Transaction.occurred_on >= start_date)
    if end_date is not None:
        conditions.append(Transaction.occurred_on <= end_date)
    if minimum_amount_minor is not None:
        conditions.append(Transaction.amount_minor >= minimum_amount_minor)
    if maximum_amount_minor is not None:
        conditions.append(Transaction.amount_minor <= maximum_amount_minor)
    if cleared is not None:
        conditions.append(Transaction.is_cleared.is_(cleared))
    if reconciled is not None:
        conditions.append(Transaction.is_reconciled.is_(reconciled))
    if flag:
        conditions.append(Transaction.flag.in_(flag))
    if tag:
        # Tags are normalized strings. JSON containment differs between SQLite
        # test fixtures and PostgreSQL, so compare the serialized array with
        # delimiter-aware patterns rather than hydrating every transaction.
        serialized_tags = cast(Transaction.tags, String)
        conditions.append(or_(*[
            or_(
                serialized_tags.like(f'%"{value}"%'),
                serialized_tags.like(f"%'{value}'%"),
            ) for value in tag
        ]))
    if actor_user_id:
        conditions.append(Transaction.created_by_user_id.in_(actor_user_id))
    if is_transfer is not None:
        conditions.append(Transaction.transfer_id.is_not(None) if is_transfer else Transaction.transfer_id.is_(None))
    if is_scheduled_realization is not None:
        conditions.append(
            Transaction.scheduled_transaction_id.is_not(None)
            if is_scheduled_realization else Transaction.scheduled_transaction_id.is_(None)
        )

    has_category = or_(Transaction.category_id.is_not(None), Transaction.splits.any())
    if transaction_type == "transfer":
        conditions.append(Transaction.transfer_id.is_not(None))
    elif transaction_type == "income":
        conditions.extend([Transaction.transfer_id.is_(None), Transaction.amount_minor > 0, ~has_category])
    elif transaction_type == "spending":
        conditions.extend([Transaction.transfer_id.is_(None), Transaction.amount_minor < 0, has_category])
    elif transaction_type == "refund":
        conditions.extend([Transaction.transfer_id.is_(None), Transaction.amount_minor > 0, has_category])
    elif transaction_type == "interest_charge":
        conditions.append(or_(
            Transaction.financial_classification == "interest_charge",
            Transaction.splits.any(TransactionSplit.financial_classification == "interest_charge"),
        ))
    if lifecycle_status:
        conditions.append(Transaction.status.in_(lifecycle_status))

    orderings = {
        "date_asc": (Transaction.occurred_on.asc(), Transaction.created_at.asc(), Transaction.id.asc()),
        "amount_desc": (Transaction.amount_minor.desc(), Transaction.occurred_on.desc(), Transaction.id.asc()),
        "amount_asc": (Transaction.amount_minor.asc(), Transaction.occurred_on.desc(), Transaction.id.asc()),
        "payee_asc": (func.lower(Transaction.payee_name).asc(), Transaction.occurred_on.desc(), Transaction.id.asc()),
        "date_desc": (Transaction.occurred_on.desc(), Transaction.created_at.desc(), Transaction.id.desc()),
    }
    page_conditions = list(conditions)
    if cursor is not None:
        try:
            payload = json.loads(base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8"))
            if payload.get("v") != 1 or payload.get("sort") != sort:
                raise ValueError
            cursor_id = str(payload["id"])
            cursor_date = date.fromisoformat(payload["date"])
            if sort in {"date_asc", "date_desc"}:
                cursor_created = datetime.fromisoformat(payload["created"])
                if sort == "date_asc":
                    page_conditions.append(or_(
                        Transaction.occurred_on > cursor_date,
                        and_(Transaction.occurred_on == cursor_date, Transaction.created_at > cursor_created),
                        and_(Transaction.occurred_on == cursor_date, Transaction.created_at == cursor_created, Transaction.id > cursor_id),
                    ))
                else:
                    page_conditions.append(or_(
                        Transaction.occurred_on < cursor_date,
                        and_(Transaction.occurred_on == cursor_date, Transaction.created_at < cursor_created),
                        and_(Transaction.occurred_on == cursor_date, Transaction.created_at == cursor_created, Transaction.id < cursor_id),
                    ))
            elif sort in {"amount_asc", "amount_desc"}:
                cursor_amount = int(payload["amount"])
                amount_after = Transaction.amount_minor > cursor_amount if sort == "amount_asc" else Transaction.amount_minor < cursor_amount
                page_conditions.append(or_(
                    amount_after,
                    and_(Transaction.amount_minor == cursor_amount, Transaction.occurred_on < cursor_date),
                    and_(Transaction.amount_minor == cursor_amount, Transaction.occurred_on == cursor_date, Transaction.id > cursor_id),
                ))
            else:
                cursor_payee = str(payload["payee"])
                lowered_payee = func.lower(Transaction.payee_name)
                page_conditions.append(or_(
                    lowered_payee > cursor_payee,
                    and_(lowered_payee == cursor_payee, Transaction.occurred_on < cursor_date),
                    and_(lowered_payee == cursor_payee, Transaction.occurred_on == cursor_date, Transaction.id > cursor_id),
                ))
        except (ValueError, TypeError, KeyError, UnicodeError, json.JSONDecodeError):
            raise HTTPException(status_code=422, detail="Invalid or stale transaction cursor") from None

    total_count = db.scalar(select(func.count()).select_from(Transaction).where(*conditions)) or 0
    rows = list(db.scalars(
        select(Transaction)
        .options(selectinload(Transaction.splits))
        .where(*page_conditions)
        .order_by(*orderings[sort])
        .limit(limit + 1)
    ))
    page = rows[:limit]
    next_cursor = None
    if len(rows) > limit:
        last = page[-1]
        cursor_payload = {
            "v": 1,
            "sort": sort,
            "id": last.id,
            "date": last.occurred_on.isoformat(),
        }
        if sort in {"date_asc", "date_desc"}:
            cursor_payload["created"] = last.created_at.isoformat()
        elif sort in {"amount_asc", "amount_desc"}:
            cursor_payload["amount"] = last.amount_minor
        else:
            cursor_payload["payee"] = last.payee_name.casefold()
        payload = json.dumps(cursor_payload, separators=(",", ":"))
        next_cursor = base64.urlsafe_b64encode(payload.encode("utf-8")).decode("ascii")
    return TransactionPageResponse(items=page, next_cursor=next_cursor, total_count=total_count)


@router.get("/transactions", response_model=list[TransactionResponse])
def list_transactions(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    return transaction_response_rows(db, _visible_transactions(db, user, budget))


def _changed_transaction_fields(change: TransactionChange) -> list[str]:
    """Return field names only; snapshots remain private server audit material."""
    try:
        before = json.loads(change.before_json) if change.before_json else {}
        after = json.loads(change.after_json) if change.after_json else {}
    except (TypeError, ValueError):
        return []
    if not isinstance(before, dict) or not isinstance(after, dict):
        return []
    # Creation/deletion snapshots are intentionally summarized by their action. Detailed deltas
    # are useful only when both sides of a mutation exist.
    if not before or not after:
        return []
    ignored = {"attachment_metadata", "attachment_id", "sha256", "scheduled_transaction_id",
               "transfer_id", "reversal_of_transaction_id", "reversal_transaction_id"}
    return sorted(key for key in (set(before) | set(after)) if key not in ignored and before.get(key) != after.get(key))


def _transaction_history_context(
    db: Session, user: User, budget: Budget, changes: list[TransactionChange],
) -> dict:
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    account_ids: set[str] = set()
    category_ids: set[str] = set()
    payee_ids: set[str] = set()
    for change in changes:
        for raw in (change.before_json, change.after_json):
            try:
                snapshot = json.loads(raw) if raw else {}
            except (TypeError, ValueError):
                continue
            if not isinstance(snapshot, dict):
                continue
            if isinstance(snapshot.get("account_id"), str):
                account_ids.add(snapshot["account_id"])
            if isinstance(snapshot.get("category_id"), str):
                category_ids.add(snapshot["category_id"])
            if isinstance(snapshot.get("payee_id"), str):
                payee_ids.add(snapshot["payee_id"])
            if isinstance(snapshot.get("splits"), list):
                category_ids.update(item["category_id"] for item in snapshot["splits"]
                                    if isinstance(item, dict) and isinstance(item.get("category_id"), str))
    accounts = {row.id: row.name for row in db.scalars(select(Account).where(Account.id.in_(account_ids)))} if account_ids else {}
    category_rows = list(db.scalars(select(Category).where(Category.id.in_(category_ids)))) if category_ids else []
    group_ids = {row.group_id for row in category_rows}
    group_names = {row.id: row.name for row in db.scalars(select(CategoryGroup).where(CategoryGroup.id.in_(group_ids)))} if group_ids else {}
    categories = {row.id: f"{group_names.get(row.group_id, 'Category')} · {row.name}" for row in category_rows}
    payees = {row.id: row.display_name for row in db.scalars(select(Payee).where(Payee.id.in_(payee_ids)))} if payee_ids else {}
    return {"visible_accounts": visible_accounts, "visible_categories": visible_categories,
            "accounts": accounts, "categories": categories, "payees": payees}


def _transaction_field_changes(change: TransactionChange, context: dict) -> list[dict]:
    """Project immutable snapshots into useful display values without exposing internal IDs."""
    try:
        before = json.loads(change.before_json) if change.before_json else {}
        after = json.loads(change.after_json) if change.after_json else {}
    except (TypeError, ValueError):
        return []
    if not isinstance(before, dict) or not isinstance(after, dict):
        return []
    if not before or not after:
        return []

    visible_accounts = context["visible_accounts"]
    visible_categories = context["visible_categories"]
    accounts = context["accounts"]
    categories = context["categories"]
    payees = context["payees"]

    def snapshot_visible(snapshot: dict) -> bool:
        account_id = snapshot.get("account_id")
        if visible_accounts is not None and account_id is not None and account_id not in visible_accounts:
            return False
        category_ids = {snapshot.get("category_id")}
        splits = snapshot.get("splits")
        if isinstance(splits, list):
            category_ids.update(item.get("category_id") for item in splits if isinstance(item, dict))
        category_ids.discard(None)
        return visible_categories is None or category_ids.issubset(visible_categories)

    def identity(value, names: dict[str, str], visible: set[str] | None) -> tuple[str | None, str]:
        if value is None:
            return None, "text"
        if not isinstance(value, str) or (visible is not None and value not in visible):
            return "Private or unavailable", "restricted"
        return names.get(value, "Unavailable item"), "text"

    def display(field: str, value, snapshot: dict) -> tuple[str | None, str]:
        if value is not None and not snapshot_visible(snapshot):
            return "Private or unavailable", "restricted"
        if field == "account_id":
            return identity(value, accounts, visible_accounts)
        if field == "category_id":
            return identity(value, categories, visible_categories)
        if field == "payee_id":
            return identity(value, payees, None)
        if field == "amount_minor":
            return (str(value), "money_minor") if isinstance(value, int) else (None, "money_minor")
        if field in {"is_cleared", "is_reconciled"}:
            labels = ({True: "Cleared", False: "Uncleared"} if field == "is_cleared"
                      else {True: "Reconciled", False: "Not reconciled"})
            return labels.get(value), "state"
        if field == "occurred_on":
            return (str(value), "date") if value is not None else (None, "date")
        if field == "tags":
            return (" ".join(f"#{item}" for item in value), "list") if isinstance(value, list) else (None, "list")
        if field == "splits":
            count = len(value) if isinstance(value, list) else 0
            return (f"{count} split line{'s' if count != 1 else ''}", "state")
        if value is None:
            return None, "text"
        if isinstance(value, bool):
            return ("Yes" if value else "No"), "state"
        return str(value), "text"

    internal = {"attachment_metadata", "attachment_id", "sha256", "scheduled_transaction_id",
                "transfer_id", "reversal_of_transaction_id", "reversal_transaction_id"}
    rows = []
    for field in sorted((set(before) | set(after)) - internal):
        if before.get(field) == after.get(field):
            continue
        before_value, before_kind = display(field, before.get(field), before)
        after_value, after_kind = display(field, after.get(field), after)
        rows.append({
            "field": field,
            "value_kind": "restricted" if "restricted" in (before_kind, after_kind) else after_kind if after_value is not None else before_kind,
            "before_value": before_value,
            "after_value": after_value,
        })
    return rows


def _transaction_change_rows(
    db: Session, user: User, budget: Budget, changes: list[TransactionChange],
    transactions: dict[str, Transaction] | None = None,
) -> list[dict]:
    actor_ids = {item.actor_user_id for item in changes}
    names = {item.id: item.display_name for item in db.scalars(
        select(User).where(User.id.in_(actor_ids))
    )} if actor_ids else {}
    history_context = _transaction_history_context(db, user, budget, changes)
    transactions = transactions or {}
    return [{
        "id": item.id,
        "transaction_id": item.transaction_id,
        "transaction_payee_name": transactions[item.transaction_id].payee_name
            if item.transaction_id in transactions else None,
        "transaction_occurred_on": transactions[item.transaction_id].occurred_on
            if item.transaction_id in transactions else None,
        "action": item.action,
        "actor_user_id": item.actor_user_id,
        "actor_display_name": names.get(item.actor_user_id),
        "changed_fields": _changed_transaction_fields(item),
        "changes": _transaction_field_changes(item, history_context),
        "created_at": item.created_at,
    } for item in changes]


@router.get("/transaction-changes", response_model=list[TransactionChangeResponse])
def recent_transaction_changes(
    budget_id: str,
    limit: int = Query(default=5, ge=1, le=25),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    """Return recent visible edits for Activity without leaking hidden transaction activity."""
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    visible_transactions = select(Transaction.id).where(*transaction_visibility_conditions(db, user, budget))
    changes = list(db.scalars(select(TransactionChange).where(
        TransactionChange.budget_id == budget.id,
        TransactionChange.transaction_id.in_(visible_transactions),
    ).order_by(TransactionChange.created_at.desc(), TransactionChange.id.desc()).limit(limit)))
    transaction_ids = {item.transaction_id for item in changes}
    transactions = {item.id: item for item in db.scalars(select(Transaction).where(
        Transaction.id.in_(transaction_ids)
    ))} if transaction_ids else {}
    return _transaction_change_rows(db, user, budget, changes, transactions)


@router.get("/transactions/{transaction_id}/history", response_model=list[TransactionChangeResponse])
def transaction_history(
    budget_id: str,
    transaction_id: str,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    transaction = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id,
        Transaction.budget_id == budget.id,
    ))
    if transaction is None or not _can_access_transaction_resources(db, user, budget, transaction):
        raise HTTPException(status_code=404, detail="Transaction not found")
    changes = list(db.scalars(select(TransactionChange).where(
        TransactionChange.budget_id == budget.id,
        TransactionChange.transaction_id == transaction.id,
    ).order_by(TransactionChange.created_at.desc(), TransactionChange.id.desc()).offset(offset).limit(limit)))
    return _transaction_change_rows(db, user, budget, changes)


@router.post("/transactions", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def create_transaction(
    budget_id: str,
    body: TransactionCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    digest = "v1:" + hashlib.sha256(json.dumps(
        body.model_dump(mode="json", exclude={"client_operation_id"}),
        sort_keys=True, separators=(",", ":"),
    ).encode()).hexdigest()
    def replay() -> Optional[Transaction]:
        if body.client_operation_id is None:
            return None
        receipt = db.get(TransactionCreationReceipt, (budget_id, user.id, body.client_operation_id))
        if receipt is None:
            legacy = db.scalar(select(Transaction).where(
                Transaction.budget_id == budget_id, Transaction.created_by_user_id == user.id,
                Transaction.client_operation_id == body.client_operation_id,
            ))
            if legacy is not None:
                budget = require_budget_capability(db, user, budget_id, "create_transaction")
                if not _can_access_transaction_resources(db, user, budget, legacy):
                    raise HTTPException(status_code=404, detail="Transaction not found")
                raise HTTPException(status_code=409, detail="Original request cannot be verified. Refresh and review this transaction.")
            return None
        budget = require_budget_capability(db, user, budget_id, "create_transaction")
        existing = db.get(Transaction, receipt.transaction_id)
        if existing is None or not _can_access_transaction_resources(db, user, budget, existing):
            raise HTTPException(status_code=404, detail="Transaction not found")
        if receipt.request_digest is None:
            raise HTTPException(status_code=409, detail="Original request cannot be verified. Refresh and review this transaction.")
        if receipt.request_digest != digest:
            raise HTTPException(status_code=409, detail="Operation identity was already used for different transaction details.")
        return existing
    existing = replay()
    if existing is not None:
        return existing
    transaction = create_transaction_in_session(budget_id, body, user=user, db=db)
    if body.client_operation_id is not None:
        db.add(TransactionCreationReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=body.client_operation_id, transaction_id=transaction.id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if body.client_operation_id is None:
            raise
        existing = replay()
        if existing is None:
            raise
        return existing
    db.refresh(transaction)
    return transaction


def create_transaction_in_session(
    budget_id: str, body: TransactionCreate, *, user: User, db: Session,
) -> Transaction:
    """Canonical creation; caller owns commit/rollback, never authorization bypass.

    Keep reserve events, identity resolution and audit in the same transaction.
    A caller must roll back the unit of work if any operation fails.
    """
    body = body.model_copy(deep=True)
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    lock_budget(db, budget_id)
    if body.occurred_on > today():
        raise HTTPException(status_code=422, detail="Future transactions belong in the planning layer")
    account = db.scalar(select(Account).where(Account.id == body.account_id).with_for_update())
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid account")
    if (body.financial_classification is not None or any(split.financial_classification is not None for split in body.splits)) and account.account_type not in {"credit", "loan", "mortgage"}:
        raise HTTPException(status_code=422, detail="Interest charges require a debt account")
    if not can_access_resource(db, user, budget, "account", account.id):
        raise HTTPException(status_code=422, detail="Invalid account")
    category_ids = ([body.category_id] if body.category_id is not None else []) + [
        split.category_id for split in body.splits
    ]
    if category_ids and not account.is_on_budget:
        raise HTTPException(status_code=422, detail="Tracking accounts cannot affect budget categories")
    if len(category_ids) != len(set(category_ids)):
        raise HTTPException(status_code=422, detail="Duplicate split category")
    categories_by_id: dict[str, Category] = {}
    for category_id in category_ids:
        category = db.scalar(select(Category).where(Category.id == category_id).with_for_update())
        if category is None or category.budget_id != budget_id or category.is_archived:
            raise HTTPException(status_code=422, detail="Invalid category")
        if not can_access_resource(db, user, budget, "category", category.id):
            raise HTTPException(status_code=422, detail="Invalid category")
        categories_by_id[category_id] = category
    try:
        body.payee_id, body.payee_name = resolve_or_create_payee(
            db, budget=budget, user=user, payee_id=body.payee_id, payee_name=body.payee_name,
        )
    except ValueError:
        raise HTTPException(status_code=422, detail="Invalid payee") from None
    transaction_values = body.model_dump(exclude={"splits"})
    transaction = Transaction(
        budget_id=budget_id,
        created_by_user_id=user.id,
        **transaction_values,
    )
    transaction.splits = [TransactionSplit(**split.model_dump()) for split in body.splits]
    db.add(transaction)
    db.flush()
    category_amounts = (
        [(categories_by_id[body.category_id], body.amount_minor)]
        if body.category_id is not None
        else [(categories_by_id[split.category_id], split.amount_minor) for split in body.splits]
    )
    add_purchase_reserve_events(
        db,
        account=account,
        transaction=transaction,
        category_amounts=category_amounts,
        actor=user,
    )
    record_transaction_change(db, transaction, user, "created", after=transaction_snapshot(transaction))
    db.flush()
    return transaction


@router.post("/transactions/bulk", response_model=list[TransactionResponse])
def bulk_update_transactions(
    budget_id: str,
    body: TransactionBulkUpdateRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Transaction]:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    # Share reconciliation's critical section before taking transaction locks.
    # Otherwise quick Unclear can commit after review validation but before R is set.
    lock_budget(db, budget_id)
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id, Transaction.id.in_(body.transaction_ids),
    ).order_by(Transaction.id).with_for_update()))
    if len(transactions) != len(body.transaction_ids):
        raise HTTPException(status_code=404, detail="One or more transactions were not found")
    for transaction in transactions:
        if not _can_access_transaction_resources(db, user, budget, transaction):
            raise HTTPException(status_code=404, detail="One or more transactions were not found")
        if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
            raise HTTPException(status_code=403, detail="You may only edit your own transactions")
    by_id = {transaction.id: transaction for transaction in transactions}
    ordered = [by_id[transaction_id] for transaction_id in body.transaction_ids]
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "transaction_bulk", "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "transaction_bulk" or receipt.resource_id != body.transaction_ids[0] or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            # Acknowledge only after current capability, ownership and whole-resource checks.
            return ordered
    for transaction in ordered:
        if transaction.status != "posted":
            raise HTTPException(status_code=409, detail="Voided and reversal transactions are immutable")
        if transaction.is_reconciled:
            raise HTTPException(status_code=409, detail="Reconciled transactions cannot be changed in bulk")
        if transaction.transfer_id is not None or transaction.scheduled_transaction_id is not None or transaction.payee_name in {"Starting Balance", "Reconciliation adjustment"}:
            raise HTTPException(status_code=409, detail="System-linked transactions must be changed through their specialized workflow")

    if body.expected_revisions is not None and any(
        body.expected_revisions[transaction.id] != TransactionResponse.model_validate(transaction).revision
        for transaction in ordered
    ):
        raise HTTPException(status_code=409, detail="One or more transactions changed. Refresh and review before applying this edit.")
    proposed_tags = {}
    if body.action == "add_tags":
        for transaction in ordered:
            tags = list(dict.fromkeys([*transaction.tags, *body.tags]))
            if len(tags) > 20:
                raise HTTPException(status_code=422, detail="A transaction may have at most 20 tags. Remove a tag before adding more.")
            proposed_tags[transaction.id] = tags
    for transaction in ordered:
        before = transaction_snapshot(transaction)
        if body.action == "set_cleared":
            transaction.is_cleared = bool(body.cleared)
        elif body.action == "set_flag":
            transaction.flag = body.flag
        elif body.action == "add_tags":
            transaction.tags = proposed_tags[transaction.id]
        else:
            removed = set(body.tags)
            transaction.tags = [tag for tag in transaction.tags if tag not in removed]
        after = transaction_snapshot(transaction)
        if before != after:
            record_transaction_change(db, transaction, user, "bulk_updated", before=before, after=after)
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="transaction_bulk", resource_id=body.transaction_ids[0],
            request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return bulk_update_transactions(budget_id, body, user, db)
    for transaction in ordered:
        db.refresh(transaction)
    return ordered


@router.post("/transactions/{transaction_id}/duplicate", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def duplicate_transaction(
    budget_id: str,
    transaction_id: str,
    body: TransactionDuplicateRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    original = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id, Transaction.budget_id == budget_id,
    ))
    if original is None or not _can_access_transaction_resources(db, user, budget, original):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if original.status != "posted" or original.transfer_id is not None or original.scheduled_transaction_id is not None or original.payee_name in {"Starting Balance", "Reconciliation adjustment"}:
        raise HTTPException(status_code=409, detail="This system-linked transaction must be recreated through its specialized workflow")
    duplicate = create_transaction(
        budget_id,
        TransactionCreate(
            account_id=original.account_id,
            category_id=original.category_id,
            payee_id=original.payee_id,
            amount_minor=original.amount_minor,
            occurred_on=body.occurred_on,
            payee_name=original.payee_name,
            memo=original.memo,
            financial_classification=original.financial_classification,
            is_cleared=False,
            flag=original.flag,
            tags=list(original.tags),
            attachment_metadata=[],
            splits=[{"category_id": split.category_id, "amount_minor": split.amount_minor, "memo": split.memo, "financial_classification": split.financial_classification} for split in original.splits],
        ),
        user,
        db,
    )
    record_transaction_change(db, duplicate, user, "duplicated", before=transaction_snapshot(original), after=transaction_snapshot(duplicate))
    db.commit()
    db.refresh(duplicate)
    return duplicate


@router.post("/transactions/{transaction_id}/void", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def void_transaction(
    budget_id: str,
    transaction_id: str,
    body: TransactionVoidRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    budget = require_budget_capability(db, user, budget_id, "delete_transaction")
    lock_budget(db, budget_id)
    original = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id, Transaction.budget_id == budget_id,
    ).with_for_update())
    if original is None or not _can_access_transaction_resources(db, user, budget, original):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if original.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only void your own transactions")
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "transaction_void", "transaction_id": transaction_id,
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "transaction_void" or receipt.resource_id != transaction_id or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            reversal = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
                Transaction.id == original.reversal_transaction_id, Transaction.budget_id == budget_id,
                Transaction.reversal_of_transaction_id == original.id,
            ))
            if reversal is None or not _can_access_transaction_resources(db, user, budget, reversal):
                raise HTTPException(status_code=404, detail="Reversal transaction not found")
            return reversal
    if body.expected_revision is not None and body.expected_revision != TransactionResponse.model_validate(original).revision:
        raise HTTPException(status_code=409, detail="This transaction changed. Refresh and review before voiding it.")
    reversal = void_transaction_in_session(
        budget=budget, original=original, reason=body.reason, user=user, db=db,
    )
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="transaction_void", resource_id=transaction_id,
            request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return void_transaction(budget_id=budget_id, transaction_id=transaction_id, body=body, user=user, db=db)
    db.refresh(reversal)
    return reversal


def void_transaction_in_session(
    *, budget: Budget, original: Transaction | None, reason: str,
    user: User, db: Session,
) -> Transaction:
    """Apply one canonical void without committing, so callers can compose atomic workflows."""
    if original is None or not _can_access_transaction_resources(db, user, budget, original):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if original.status != "posted":
        raise HTTPException(status_code=409, detail="Only a posted transaction can be voided")
    if original.transfer_id is not None:
        raise HTTPException(status_code=409, detail="Linked transfers cannot be voided one leg at a time")
    if original.is_reconciled:
        raise HTTPException(status_code=409, detail="Reconciled transactions require a new explicit correcting transaction")
    if original.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only void your own transactions")
    category_ids = ([original.category_id] if original.category_id else []) + [item.category_id for item in original.splits]
    account = db.scalar(select(Account).where(Account.id == original.account_id).with_for_update())
    categories = {item.id: item for item in db.scalars(select(Category).where(Category.id.in_(category_ids)).with_for_update())} if category_ids else {}
    before_snapshot = transaction_snapshot(original)
    now = datetime.now(timezone.utc)
    reversal = Transaction(
        budget_id=budget.id, account_id=original.account_id, category_id=original.category_id,
        payee_id=original.payee_id, amount_minor=-original.amount_minor, occurred_on=today(),
        payee_name=f"Reversal: {original.payee_name or 'Transaction'}"[:150],
        memo=(f"Void reversal. {reason}" if reason else "Void reversal.")[:500],
        financial_classification=original.financial_classification,
        is_cleared=False, flag=original.flag, tags=list(original.tags), attachment_metadata=[],
        created_by_user_id=user.id, status="reversal", reversal_of_transaction_id=original.id,
    )
    reversal.splits = [TransactionSplit(category_id=item.category_id, amount_minor=-item.amount_minor, memo=item.memo, financial_classification=item.financial_classification) for item in original.splits]
    db.add(reversal)
    db.flush()
    category_amounts = ([(categories[original.category_id], -original.amount_minor)] if original.category_id else [(categories[item.category_id], -item.amount_minor) for item in original.splits])
    add_purchase_reserve_events(db, account=account, transaction=reversal, category_amounts=category_amounts, actor=user)
    original.status = "voided"
    original.voided_at = now
    original.voided_by_user_id = user.id
    original.void_reason = reason or None
    original.reversal_transaction_id = reversal.id
    record_transaction_change(db, original, user, "voided", before=before_snapshot, after=transaction_snapshot(original))
    record_transaction_change(db, reversal, user, "reversal_created", after=transaction_snapshot(reversal))
    return reversal


@router.post("/transactions/{transaction_id}/schedule", response_model=ScheduledTransactionResponse, status_code=status.HTTP_201_CREATED)
def create_schedule_from_transaction(
    budget_id: str,
    transaction_id: str,
    body: TransactionScheduleRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ScheduledTransaction:
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    original = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(Transaction.id == transaction_id, Transaction.budget_id == budget_id))
    if original is None or not _can_access_transaction_resources(db, user, budget, original):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if original.status != "posted" or original.transfer_id is not None or original.payee_name in {"Starting Balance", "Reconciliation adjustment"}:
        raise HTTPException(status_code=409, detail="This transaction cannot be used as a recurring template")
    if original.splits:
        raise HTTPException(status_code=409, detail="Split schedules are not supported yet")
    next_date = body.next_date or next_occurrence(original.occurred_on, body.recurrence_unit, body.interval_count)
    while next_date is not None and next_date <= today():
        next_date = next_occurrence(next_date, body.recurrence_unit, body.interval_count)
    if next_date is None or next_date <= today():
        raise HTTPException(status_code=422, detail="Next occurrence must be in the future")
    schedule = ScheduledTransaction(
        budget_id=budget_id, account_id=original.account_id, category_id=original.category_id,
        payee_id=original.payee_id, name=original.payee_name or "Recurring transaction", amount_minor=original.amount_minor,
        next_date=next_date, recurrence_unit=body.recurrence_unit, interval_count=body.interval_count,
        memo=original.memo, is_active=True, created_by_user_id=user.id,
        financial_classification=original.financial_classification,
    )
    db.add(schedule)
    db.flush()
    record_transaction_change(db, original, user, "schedule_created", before=transaction_snapshot(original), after=json.dumps({"scheduled_transaction_id": schedule.id}))
    db.commit()
    db.refresh(schedule)
    return schedule


def _attachment_transaction(db: Session, user: User, budget: Budget, transaction_id: str) -> Transaction:
    transaction = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id, Transaction.budget_id == budget.id,
    ))
    if transaction is None or not _can_access_transaction_resources(db, user, budget, transaction):
        raise HTTPException(status_code=404, detail="Transaction not found")
    return transaction


def _attachment_store(request: Request) -> AttachmentStorage:
    settings = request.app.state.settings
    return AttachmentStorage(settings.attachment_storage_path, settings.jwt_secret, settings.attachment_encryption_key)


@router.get("/transactions/{transaction_id}/attachments", response_model=list[TransactionAttachmentResponse])
def list_transaction_attachments(
    budget_id: str, transaction_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> list[TransactionAttachment]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    _attachment_transaction(db, user, budget, transaction_id)
    return list(db.scalars(select(TransactionAttachment).where(
        TransactionAttachment.transaction_id == transaction_id, TransactionAttachment.detached_at.is_(None),
    ).order_by(TransactionAttachment.created_at)))


@router.post("/transactions/{transaction_id}/attachments", response_model=TransactionAttachmentResponse, status_code=status.HTTP_201_CREATED)
def attach_transaction_file(
    request: Request,
    budget_id: str,
    transaction_id: str,
    content: bytes = Body(..., media_type="application/octet-stream"),
    filename: str = Header(..., alias="X-Attachment-Filename"),
    content_type: str = Header(..., alias="X-Attachment-Content-Type"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransactionAttachment:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    transaction = _attachment_transaction(db, user, budget, transaction_id)
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only attach files to your own transactions")
    if transaction.status == "reversal":
        raise HTTPException(status_code=409, detail="Attach supporting documents to the original transaction")
    count = db.scalar(select(func.count()).select_from(TransactionAttachment).where(
        TransactionAttachment.transaction_id == transaction_id, TransactionAttachment.detached_at.is_(None),
    )) or 0
    if count >= 20:
        raise HTTPException(status_code=422, detail="A transaction may have at most 20 attachments")
    normalized_type = content_type.split(";", 1)[0].strip().lower()
    try:
        validate_content(content, normalized_type)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    attachment = TransactionAttachment(
        budget_id=budget_id, transaction_id=transaction_id, filename=safe_filename(filename),
        content_type=normalized_type, byte_count=len(content), sha256=hashlib.sha256(content).hexdigest(),
        storage_key=str(uuid4()), created_by_user_id=user.id,
    )
    storage = _attachment_store(request)
    storage.write(attachment.storage_key, content)
    db.add(attachment)
    record_transaction_change(db, transaction, user, "attachment_added", after=json.dumps({"attachment_id": attachment.id, "filename": attachment.filename, "sha256": attachment.sha256}, sort_keys=True))
    try:
        db.commit()
    except Exception:
        storage.delete(attachment.storage_key)
        raise
    db.refresh(attachment)
    return attachment


@router.get("/transactions/{transaction_id}/attachments/{attachment_id}")
def download_transaction_attachment(
    request: Request, budget_id: str, transaction_id: str, attachment_id: str,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> Response:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    _attachment_transaction(db, user, budget, transaction_id)
    attachment = db.scalar(select(TransactionAttachment).where(
        TransactionAttachment.id == attachment_id, TransactionAttachment.transaction_id == transaction_id,
        TransactionAttachment.budget_id == budget_id, TransactionAttachment.detached_at.is_(None),
    ))
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    try:
        content = _attachment_store(request).read(attachment.storage_key)
    except (FileNotFoundError, ValueError):
        raise HTTPException(status_code=500, detail="Attachment storage is unavailable") from None
    if hashlib.sha256(content).hexdigest() != attachment.sha256:
        raise HTTPException(status_code=500, detail="Attachment integrity check failed")
    return Response(content, media_type=attachment.content_type, headers={
        "Content-Disposition": f'attachment; filename="{attachment.filename.replace(chr(34), "")}"',
        "X-Content-SHA256": attachment.sha256,
    })


@router.delete("/transactions/{transaction_id}/attachments/{attachment_id}", status_code=status.HTTP_204_NO_CONTENT)
def detach_transaction_attachment(
    budget_id: str, transaction_id: str, attachment_id: str,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    transaction = _attachment_transaction(db, user, budget, transaction_id)
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only detach files from your own transactions")
    attachment = db.scalar(select(TransactionAttachment).where(
        TransactionAttachment.id == attachment_id, TransactionAttachment.transaction_id == transaction_id,
        TransactionAttachment.budget_id == budget_id, TransactionAttachment.detached_at.is_(None),
    ).with_for_update())
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    now = datetime.now(timezone.utc)
    attachment.detached_at = now
    attachment.detached_by_user_id = user.id
    attachment.purge_after = now + timedelta(days=30)
    record_transaction_change(db, transaction, user, "attachment_detached", before=json.dumps({"attachment_id": attachment.id, "sha256": attachment.sha256}, sort_keys=True))
    db.commit()


@router.post("/attachments/garbage-collect")
def garbage_collect_attachments(
    request: Request, budget_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db),
) -> dict[str, int]:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    now = datetime.now(timezone.utc)
    rows = list(db.scalars(select(TransactionAttachment).where(
        TransactionAttachment.budget_id == budget_id,
        TransactionAttachment.purge_after.is_not(None), TransactionAttachment.purge_after <= now,
    )))
    storage = _attachment_store(request)
    for attachment in rows:
        storage.delete(attachment.storage_key)
        db.delete(attachment)
    db.commit()
    return {"purged": len(rows)}


@router.put("/transactions/{transaction_id}", response_model=TransactionResponse)
def update_transaction(
    budget_id: str,
    transaction_id: str,
    body: TransactionUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    original_body = body.model_copy(deep=True)
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    lock_budget(db, budget_id)
    transaction = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id,
        Transaction.budget_id == budget_id,
    ).with_for_update())
    if transaction is None or transaction.transfer_id is not None or not _can_access_transaction_resources(db, user, budget, transaction):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only edit your own transactions")
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "transaction_update", "transaction_id": transaction_id,
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id", "client_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "transaction_update" or receipt.resource_id != transaction_id or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            # Acknowledgement only: current authorization applies, but a later reconciliation
            # or lifecycle change must not turn an accepted retry into another mutation.
            return transaction
    if transaction.status != "posted":
        raise HTTPException(status_code=409, detail="Voided and reversal transactions are immutable")
    if transaction.is_reconciled:
        raise HTTPException(status_code=409, detail="Reconciled transactions cannot be edited")
    before_snapshot = transaction_snapshot(transaction)
    if body.expected_revision is not None and body.expected_revision != TransactionResponse.model_validate(transaction).revision:
        raise HTTPException(status_code=409, detail="This transaction changed. Refresh and review before applying this edit.")
    if body.occurred_on > today():
        raise HTTPException(status_code=422, detail="Future transactions belong in the planning layer")
    account = db.scalar(select(Account).where(Account.id == body.account_id).with_for_update())
    if account is None or account.budget_id != budget_id or account.is_closed or not can_access_resource(db, user, budget, "account", account.id):
        raise HTTPException(status_code=422, detail="Invalid account")
    if (body.financial_classification is not None or any(split.financial_classification is not None for split in body.splits)) and account.account_type not in {"credit", "loan", "mortgage"}:
        raise HTTPException(status_code=422, detail="Interest charges require a debt account")
    category_ids = ([body.category_id] if body.category_id is not None else []) + [split.category_id for split in body.splits]
    if category_ids and not account.is_on_budget:
        raise HTTPException(status_code=422, detail="Tracking accounts cannot affect budget categories")
    if len(category_ids) != len(set(category_ids)):
        raise HTTPException(status_code=422, detail="Duplicate split category")
    categories_by_id: dict[str, Category] = {}
    for category_id in category_ids:
        category = db.get(Category, category_id)
        if category is None or category.budget_id != budget_id or category.is_archived or not can_access_resource(db, user, budget, "category", category.id):
            raise HTTPException(status_code=422, detail="Invalid category")
        categories_by_id[category_id] = category
    try:
        body.payee_id, body.payee_name = resolve_or_create_payee(
            db, budget=budget, user=user, payee_id=body.payee_id, payee_name=body.payee_name,
        )
    except ValueError:
        raise HTTPException(status_code=422, detail="Invalid payee") from None
    # Metadata-only saves must retain the original funded/unfunded observation. Re-evaluating
    # a purchase against later postings (including same-day purchases) can move payment money.
    financial_changed = any(
        getattr(transaction, key) != getattr(body, key)
        for key in ("account_id", "category_id", "amount_minor", "occurred_on", "financial_classification")
    ) or sorted(
        (split.category_id, split.amount_minor, split.financial_classification or "") for split in transaction.splits
    ) != sorted(
        (split.category_id, split.amount_minor, split.financial_classification or "") for split in body.splits
    )
    if financial_changed:
        db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.source_transaction_id == transaction.id))
    # Creation retry identity is immutable, including when an edit omits it.
    values = body.model_dump(exclude={"splits", "expected_revision", "client_operation_id", "mutation_operation_id"})
    for key, value in values.items():
        setattr(transaction, key, value)
    if financial_changed:
        transaction.splits = [TransactionSplit(**split.model_dump()) for split in body.splits]
    else:
        split_memos = {split.category_id: split.memo for split in body.splits}
        for split in transaction.splits:
            split.memo = split_memos[split.category_id]
    db.flush()
    category_amounts = (
        [(categories_by_id[body.category_id], body.amount_minor)]
        if body.category_id is not None else [(categories_by_id[split.category_id], split.amount_minor) for split in body.splits]
    )
    if financial_changed:
        add_purchase_reserve_events(db, account=account, transaction=transaction, category_amounts=category_amounts, actor=user)
    after_snapshot = transaction_snapshot(transaction)
    if before_snapshot != after_snapshot:
        record_transaction_change(db, transaction, user, "updated", before=before_snapshot, after=after_snapshot)
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="transaction_update", resource_id=transaction_id,
            request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        # Cross-resource UUID collision rolls back all tentative effects. Re-enter the same
        # guarded acknowledgement path with fresh authoritative resource state.
        return update_transaction(budget_id, transaction_id, original_body, user, db)
    db.refresh(transaction)
    return transaction


@router.delete("/transactions/{transaction_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_transaction(
    budget_id: str,
    transaction_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "delete_transaction")
    lock_budget(db, budget_id)
    transaction = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(Transaction.id == transaction_id))
    if (transaction is None or transaction.budget_id != budget_id or transaction.transfer_id is not None
            or not _can_access_transaction_resources(db, user, budget, transaction)):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if transaction.status != "posted":
        raise HTTPException(status_code=409, detail="Voided and reversal transactions cannot be deleted")
    if transaction.is_reconciled:
        raise HTTPException(status_code=409, detail="Reconciled transactions cannot be deleted")
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only delete your own transactions")
    attachment_count = db.scalar(select(func.count()).select_from(TransactionAttachment).where(
        TransactionAttachment.transaction_id == transaction.id,
    )) or 0
    if attachment_count:
        raise HTTPException(status_code=409, detail="Transactions with retained attachment history cannot be deleted; use Void with Reversal")
    record_transaction_change(db, transaction, user, "deleted", before=transaction_snapshot(transaction))
    db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.source_transaction_id == transaction.id))
    db.delete(transaction)
    db.commit()


@router.post("/transfers", response_model=TransferResponse, status_code=status.HTTP_201_CREATED)
def create_transfer(
    budget_id: str,
    body: IdentifiedTransferCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransferResponse:
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    lock_budget(db, budget_id)
    if body.occurred_on > today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
    locked_accounts = list(db.scalars(select(Account).where(Account.id.in_([
        body.source_account_id, body.destination_account_id
    ])).order_by(Account.id).with_for_update()))
    by_id = {account.id: account for account in locked_accounts}
    source = by_id.get(body.source_account_id)
    destination = by_id.get(body.destination_account_id)
    if any(
        account is None or account.budget_id != budget_id or account.is_closed
        for account in (source, destination)
    ):
        raise HTTPException(status_code=422, detail="Invalid transfer account")
    if any(not can_access_resource(db, user, budget, "account", account.id) for account in (source, destination)):
        raise HTTPException(status_code=422, detail="Invalid transfer account")
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "transfer_create",
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "transfer_create" or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            # Acknowledgement is read-only. Do not lock legs after locking accounts:
            # transfer edits acquire legs first, so reversing that order can deadlock.
            legs = _locked_transfer_legs(db, budget_id, receipt.resource_id, lock=False)
            if any(not can_access_resource(db, user, budget, "account", leg.account_id) for leg in legs):
                raise HTTPException(status_code=404, detail="Transfer not found")
            return TransferResponse(transfer_id=receipt.resource_id,
                source=TransactionResponse.model_validate(next(leg for leg in legs if leg.amount_minor < 0)),
                destination=TransactionResponse.model_validate(next(leg for leg in legs if leg.amount_minor > 0)))
    transfer_id = str(uuid4())
    common = {
        "budget_id": budget_id,
        "occurred_on": body.occurred_on,
        "memo": body.memo,
        "payee_name": "Transfer",
        "is_cleared": body.is_cleared,
        "created_by_user_id": user.id,
        "transfer_id": transfer_id,
    }
    source_transaction = Transaction(
        account_id=body.source_account_id,
        amount_minor=-body.amount_minor,
        **common,
    )
    destination_transaction = Transaction(
        account_id=body.destination_account_id,
        amount_minor=body.amount_minor,
        **common,
    )
    db.add_all([source_transaction, destination_transaction])
    if source.account_type == "credit" and destination.account_type == "credit":
        raise HTTPException(status_code=422, detail="Credit-to-credit transfers are not supported")
    if destination.account_type == "credit":
        add_payment_reserve_event(
            db,
            credit_account=destination,
            transfer_id=transfer_id,
            occurred_on=body.occurred_on,
            amount_minor=-body.amount_minor,
            actor=user,
            kind="payment",
        )
    elif source.account_type == "credit":
        add_payment_reserve_event(
            db,
            credit_account=source,
            transfer_id=transfer_id,
            occurred_on=body.occurred_on,
            amount_minor=body.amount_minor,
            actor=user,
            kind="payment_reversal",
        )
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="transfer_create", resource_id=transfer_id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return create_transfer(budget_id, body, user, db)
    db.refresh(source_transaction)
    db.refresh(destination_transaction)
    return TransferResponse(
        transfer_id=transfer_id,
        source=TransactionResponse.model_validate(source_transaction),
        destination=TransactionResponse.model_validate(destination_transaction),
    )


def _locked_transfer_legs(db: Session, budget_id: str, transfer_id: str, *, lock: bool = True) -> list[Transaction]:
    query = select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id,
        Transaction.transfer_id == transfer_id,
    ).order_by(Transaction.id)
    legs = list(db.scalars(query.with_for_update() if lock else query))
    if len(legs) != 2 or sum(leg.amount_minor for leg in legs) != 0:
        raise HTTPException(status_code=404, detail="Transfer not found")
    return legs


def _authorize_transfer_legs(db: Session, user: User, budget: Budget, legs: list[Transaction], action: str, *, acknowledgement: bool = False) -> None:
    if any(not can_access_resource(db, user, budget, "account", leg.account_id) for leg in legs):
        raise HTTPException(status_code=404, detail="Transfer not found")
    if any(leg.created_by_user_id != user.id for leg in legs) and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail=f"You may only {action} your own transfers")
    if not acknowledgement and any(leg.is_reconciled for leg in legs):
        consequence = "modified" if action == "edit" else "deleted"
        raise HTTPException(status_code=409, detail=f"Reconciled transfers cannot be {consequence}")


@router.put("/transfers/{transfer_id}", response_model=TransferResponse)
def update_transfer(
    budget_id: str,
    transfer_id: str,
    body: TransferUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransferResponse:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    lock_budget(db, budget_id)
    if body.occurred_on > today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
    legs = _locked_transfer_legs(db, budget_id, transfer_id)
    _authorize_transfer_legs(db, user, budget, legs, "edit", acknowledgement=True)
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "transfer_update", "transfer_id": transfer_id,
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "transfer_update" or receipt.resource_id != transfer_id or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            return TransferResponse(transfer_id=transfer_id,
                source=TransactionResponse.model_validate(next(leg for leg in legs if leg.amount_minor < 0)),
                destination=TransactionResponse.model_validate(next(leg for leg in legs if leg.amount_minor > 0)))
    _authorize_transfer_legs(db, user, budget, legs, "edit")
    if body.expected_revisions is not None:
        if set(body.expected_revisions) != {leg.id for leg in legs}:
            raise HTTPException(status_code=422, detail="Expected revisions must identify both transfer legs")
        if any(body.expected_revisions[leg.id] != TransactionResponse.model_validate(leg).revision for leg in legs):
            raise HTTPException(status_code=409, detail="This transfer changed. Refresh and review before applying this edit.")
    accounts = list(db.scalars(select(Account).where(Account.id.in_([
        body.source_account_id, body.destination_account_id
    ])).order_by(Account.id).with_for_update()))
    by_id = {account.id: account for account in accounts}
    source, destination = by_id.get(body.source_account_id), by_id.get(body.destination_account_id)
    if any(account is None or account.budget_id != budget_id or account.is_closed for account in (source, destination)):
        raise HTTPException(status_code=422, detail="Invalid transfer account")
    if any(not can_access_resource(db, user, budget, "account", account.id) for account in (source, destination)):
        raise HTTPException(status_code=422, detail="Invalid transfer account")
    if source.account_type == "credit" and destination.account_type == "credit":
        raise HTTPException(status_code=422, detail="Credit-to-credit transfers are not supported")

    source_leg = next(leg for leg in legs if leg.amount_minor < 0)
    destination_leg = next(leg for leg in legs if leg.amount_minor > 0)
    before = {leg.id: transaction_snapshot(leg) for leg in legs}
    financial_changed = (
        source_leg.account_id != body.source_account_id
        or destination_leg.account_id != body.destination_account_id
        or destination_leg.amount_minor != body.amount_minor
        or any(leg.occurred_on != body.occurred_on for leg in legs)
    )
    common = {"occurred_on": body.occurred_on, "memo": body.memo, "is_cleared": body.is_cleared}
    for key, value in common.items():
        setattr(source_leg, key, value); setattr(destination_leg, key, value)
    source_leg.account_id = body.source_account_id; source_leg.amount_minor = -body.amount_minor
    destination_leg.account_id = body.destination_account_id; destination_leg.amount_minor = body.amount_minor
    if financial_changed:
        db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.transfer_id == transfer_id))
        if destination.account_type == "credit":
            add_payment_reserve_event(db, credit_account=destination, transfer_id=transfer_id, occurred_on=body.occurred_on, amount_minor=-body.amount_minor, actor=user, kind="payment")
        elif source.account_type == "credit":
            add_payment_reserve_event(db, credit_account=source, transfer_id=transfer_id, occurred_on=body.occurred_on, amount_minor=body.amount_minor, actor=user, kind="payment_reversal")
    for leg in legs:
        after = transaction_snapshot(leg)
        if before[leg.id] != after:
            record_transaction_change(db, leg, user, "updated", before=before[leg.id], after=after)
    if operation_id is not None:
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="transfer_update", resource_id=transfer_id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return update_transfer(budget_id, transfer_id, body, user, db)
    db.refresh(source_leg); db.refresh(destination_leg)
    return TransferResponse(transfer_id=transfer_id, source=TransactionResponse.model_validate(source_leg), destination=TransactionResponse.model_validate(destination_leg))


@router.delete("/transfers/{transfer_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_transfer(
    budget_id: str,
    transfer_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "delete_transaction")
    lock_budget(db, budget_id)
    legs = _locked_transfer_legs(db, budget_id, transfer_id)
    _authorize_transfer_legs(db, user, budget, legs, "delete")
    for leg in legs:
        record_transaction_change(db, leg, user, "deleted", before=transaction_snapshot(leg))
    db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.transfer_id == transfer_id))
    for leg in legs:
        db.delete(leg)
    db.commit()


@router.get("/accounts/{account_id}/reconciliations", response_model=list[ReconciliationHistoryResponse])
def reconciliation_history(
    budget_id: str,
    account_id: str,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    account = db.scalar(select(Account).where(Account.id == account_id, Account.budget_id == budget.id))
    if account is None or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    rows = list(db.scalars(select(Reconciliation).where(
        Reconciliation.budget_id == budget.id,
        Reconciliation.account_id == account.id,
    ).order_by(Reconciliation.statement_date.desc(), Reconciliation.created_at.desc(), Reconciliation.id.desc())
        .offset(offset).limit(limit)))
    actor_ids = {row.actor_user_id for row in rows}
    actor_names = {row.id: row.display_name for row in db.scalars(
        select(User).where(User.id.in_(actor_ids))
    )} if actor_ids else {}
    return [{column.key: getattr(row, column.key) for column in Reconciliation.__table__.columns}
            | {"actor_display_name": actor_names.get(row.actor_user_id)} for row in rows]


@router.get("/reconciliations", response_model=list[ReconciliationHistoryResponse])
def recent_reconciliation_history(
    budget_id: str,
    limit: int = Query(default=5, ge=1, le=25),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    """Return a bounded cross-account activity feed without widening resource scope."""
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    query = select(Reconciliation).where(Reconciliation.budget_id == budget.id)
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    if visible_accounts is not None:
        query = query.where(Reconciliation.account_id.in_(visible_accounts))
    rows = list(db.scalars(query.order_by(
        Reconciliation.created_at.desc(),
        Reconciliation.statement_date.desc(),
        Reconciliation.id.desc(),
    ).limit(limit)))
    actor_ids = {row.actor_user_id for row in rows}
    actor_names = {row.id: row.display_name for row in db.scalars(
        select(User).where(User.id.in_(actor_ids))
    )} if actor_ids else {}
    return [{column.key: getattr(row, column.key) for column in Reconciliation.__table__.columns}
            | {"actor_display_name": actor_names.get(row.actor_user_id)} for row in rows]


def _reconciliation_review(account: Account, through_date: date, transactions, actor_id: str, secret: str) -> tuple[int, str]:
    # Ordered streaming rows keep the observation bounded in memory. The account/date
    # context prevents another account or cutoff from reusing a reviewed-set token.
    digest = hmac.new(secret.encode(), json.dumps({"actor": actor_id, "budget": account.budget_id, "account": account.id,
        "through_date": through_date.isoformat(), "reconciled_balance": account.reconciled_balance_minor,
        "reconciled_at": account.reconciled_at.isoformat() if account.reconciled_at else None},
        sort_keys=True, separators=(",", ":")).encode(), hashlib.sha256)
    balance = 0
    for transaction in transactions:
        balance += transaction.amount_minor
        digest.update(json.dumps([transaction.id, TransactionResponse.model_validate(transaction).revision],
                                 separators=(",", ":")).encode())
    return balance, "v1:" + digest.hexdigest()


@router.get("/accounts/{account_id}/reconciliation-observation", response_model=ReconciliationObservationResponse)
def reconciliation_observation(
    budget_id: str, account_id: str, through_date: date,
    user: User = Depends(get_current_user), db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> ReconciliationObservationResponse:
    budget = require_budget_capability(db, user, budget_id, "reconcile_account")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    transactions = db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.account_id == account_id, Transaction.occurred_on <= through_date,
        Transaction.is_cleared.is_(True)).order_by(Transaction.id).execution_options(yield_per=500))
    balance, revision = _reconciliation_review(account, through_date, transactions, user.id, settings.jwt_secret)
    return ReconciliationObservationResponse(account_id=account_id, through_date=through_date,
        cleared_balance_minor=balance, review_revision=revision)


@router.post("/accounts/{account_id}/reconcile", response_model=ReconcileResponse)
def reconcile_account(
    budget_id: str,
    account_id: str,
    body: ReconcileRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> ReconcileResponse:
    budget = require_budget_capability(db, user, budget_id, "reconcile_account")
    # Take the shared budget lock before account/transaction work, matching bulk
    # mutation lock ordering and retaining it through receipt/history commit.
    lock_budget(db, budget_id)
    account = db.scalar(select(Account).where(Account.id == account_id).with_for_update())
    if account is None or account.budget_id != budget_id or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    operation_id = str(body.mutation_operation_id) if body.mutation_operation_id is not None else None
    digest = "v1:" + hashlib.sha256(json.dumps({
        "kind": "account_reconcile", "account_id": account_id,
        "body": body.model_dump(mode="json", exclude={"mutation_operation_id"}),
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if operation_id is not None:
        receipt = db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id))
        if receipt is not None:
            if receipt.command_kind != "account_reconcile" or receipt.request_digest != digest:
                raise HTTPException(status_code=409, detail="Operation identity was already used for a different command.")
            accepted = db.get(Reconciliation, receipt.resource_id)
            if accepted is None or accepted.budget_id != budget_id or accepted.account_id != account_id:
                raise HTTPException(status_code=404, detail="Reconciliation not found")
            # This response describes the accepted history record, not a replacement
            # observation of the account's current state. Never run reconciliation again.
            return ReconcileResponse(account_id=account_id,
                reconciled_balance_minor=accepted.statement_balance_minor,
                reconciled_transaction_count=accepted.reconciled_transaction_count,
                adjustment_transaction_id=accepted.adjustment_transaction_id,
                adjustment_amount_minor=accepted.statement_balance_minor - accepted.cleared_balance_before_minor)
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.account_id == account_id,
        Transaction.occurred_on <= body.through_date,
        Transaction.is_cleared.is_(True),
    ).order_by(Transaction.id)))
    cleared_balance, review_revision = _reconciliation_review(account, body.through_date, transactions, user.id, settings.jwt_secret)
    if body.expected_review_revision is not None and body.expected_review_revision != review_revision:
        raise HTTPException(status_code=409, detail="Reviewed reconciliation transactions changed. Refresh and review before reconciling.")
    if body.expected_cleared_balance_minor is not None and body.expected_cleared_balance_minor != cleared_balance:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": "Account changed since reconciliation started", "cleared_balance_minor": cleared_balance},
        )
    adjustment_transaction = None
    adjustment_amount = body.statement_balance_minor - cleared_balance
    if adjustment_amount != 0 and not body.create_adjustment:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": "Cleared balance does not match statement",
                "cleared_balance_minor": cleared_balance,
            },
        )
    if adjustment_amount != 0:
        if not has_capability(db, user, budget, "manage_budget_structure"):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Creating a reconciliation adjustment requires household financial authority",
            )
        adjustment_transaction = Transaction(
            budget_id=budget_id,
            account_id=account_id,
            amount_minor=adjustment_amount,
            occurred_on=body.through_date,
            payee_name="Reconciliation adjustment",
            memo=body.adjustment_reason.strip(),
            is_cleared=True,
            is_reconciled=True,
            created_by_user_id=user.id,
        )
        db.add(adjustment_transaction)
        db.flush()
        record_transaction_change(db, adjustment_transaction, user, "created",
                                  after=transaction_snapshot(adjustment_transaction))
    newly_reconciled = 0
    for transaction in transactions:
        if not transaction.is_reconciled:
            before = transaction_snapshot(transaction)
            transaction.is_reconciled = True
            newly_reconciled += 1
            record_transaction_change(db, transaction, user, "reconciled", before=before,
                                      after=transaction_snapshot(transaction))
    account.reconciled_balance_minor = body.statement_balance_minor
    account.reconciled_at = datetime.now(timezone.utc)
    reconciliation = Reconciliation(
        budget_id=budget.id,
        account_id=account.id,
        actor_user_id=user.id,
        statement_date=body.through_date,
        statement_balance_minor=body.statement_balance_minor,
        cleared_balance_before_minor=cleared_balance,
        reconciled_transaction_count=newly_reconciled,
        adjustment_transaction_id=adjustment_transaction.id if adjustment_transaction else None,
    )
    db.add(reconciliation)
    if operation_id is not None:
        db.flush()
        db.add(WorkspaceCommandReceipt(budget_id=budget_id, actor_user_id=user.id,
            operation_id=operation_id, command_kind="account_reconcile", resource_id=reconciliation.id, request_digest=digest))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if operation_id is None or db.get(WorkspaceCommandReceipt, (budget_id, user.id, operation_id)) is None:
            raise
        return reconcile_account(budget_id, account_id, body, user, db, settings)
    return ReconcileResponse(
        account_id=account.id,
        reconciled_balance_minor=body.statement_balance_minor,
        reconciled_transaction_count=newly_reconciled,
        adjustment_transaction_id=adjustment_transaction.id if adjustment_transaction else None,
        adjustment_amount_minor=adjustment_amount,
    )


@router.get("/months/{month}", response_model=MonthSummaryResponse)
def month_summary(
    budget_id: str,
    month: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MonthSummaryResponse:
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    if month.day != 1:
        raise HTTPException(status_code=422, detail="Month must be the first day of a month")
    through = month_end(month)
    archived_group_ids = select(CategoryGroup.id).where(
        CategoryGroup.budget_id == budget_id,
        CategoryGroup.is_archived.is_(True),
    )
    categories = list(db.scalars(select(Category).where(
        Category.budget_id == budget_id,
        Category.is_archived.is_(False),
        # A category whose group is archived is hidden from the plan (its money and history
        # remain in the ledger), matching category archival and the demo repository.
        Category.group_id.not_in(archived_group_ids),
    ).order_by(Category.group_id, Category.sort_order, Category.name)))
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_categories is not None:
        categories = [category for category in categories if category.id in visible_categories]
    targets = {target.category_id: target for target in db.scalars(select(CategoryTarget).where(
        CategoryTarget.budget_id == budget_id,
        CategoryTarget.is_active.is_(True),
    ))}
    snoozed_categories = set(db.scalars(select(CategoryTarget.category_id).join(
        CategoryTargetSnooze, CategoryTargetSnooze.target_id == CategoryTarget.id,
    ).where(
        CategoryTargetSnooze.budget_id == budget_id, CategoryTargetSnooze.month == month,
    )))
    # History may span decades. Stream bounded batches and keep only category accumulators;
    # do not hydrate operation objects (and their complete posting relationships) for every row.
    allocation_rows = db.execute(
        select(AllocationPosting.category_id, AllocationPosting.amount_minor, AllocationOperation.occurred_on)
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(
            AllocationPosting.budget_id == budget_id,
            AllocationOperation.occurred_on <= through,
        ).execution_options(yield_per=500)
    )
    transaction_query = select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget_id,
        Transaction.occurred_on <= through,
    )
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    if visible_accounts is not None:
        transaction_query = transaction_query.where(Transaction.account_id.in_(visible_accounts))
    transactions = db.scalars(transaction_query.execution_options(yield_per=500))
    on_budget_account_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
    )))
    cash_account_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
        Account.account_type.in_(("checking", "savings", "cash")),
    )))
    credit_account_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
        Account.account_type == "credit",
    )))

    assigned_before: dict[str, int] = {}
    assigned_current: dict[str, int] = {}
    ready_to_assign_postings = 0
    for category_id, amount_minor, occurred_on in allocation_rows:
        if category_id is None:
            ready_to_assign_postings += amount_minor
            continue
        target = assigned_current if occurred_on >= month else assigned_before
        target[category_id] = target.get(category_id, 0) + amount_minor

    activity_before: dict[str, int] = {}
    activity_current: dict[str, int] = {}
    # Current-month category activity that landed on credit accounts, tracked separately so the
    # summary can classify overspending as "became card debt" (credit) vs "needs coverage" (cash).
    credit_activity_current: dict[str, int] = {}
    unassigned_cash_to_date = 0
    for transaction in transactions:
        if (
            transaction.account_id in cash_account_ids
            and transaction.transfer_id is None
            and transaction.category_id is None
            and not transaction.splits
        ):
            unassigned_cash_to_date += transaction.amount_minor
        if transaction.account_id not in on_budget_account_ids:
            continue
        target = activity_current if transaction.occurred_on >= month else activity_before
        on_credit = transaction.account_id in credit_account_ids
        if transaction.category_id is not None:
            target[transaction.category_id] = target.get(transaction.category_id, 0) + transaction.amount_minor
            if on_credit and transaction.occurred_on >= month:
                credit_activity_current[transaction.category_id] = credit_activity_current.get(transaction.category_id, 0) + transaction.amount_minor
        for split in transaction.splits:
            target[split.category_id] = target.get(split.category_id, 0) + split.amount_minor
            if on_credit and transaction.occurred_on >= month:
                credit_activity_current[split.category_id] = credit_activity_current.get(split.category_id, 0) + split.amount_minor

    reserve_query = select(CreditCardReserveEvent).where(
        CreditCardReserveEvent.budget_id == budget_id,
        CreditCardReserveEvent.occurred_on <= through,
    )
    if visible_accounts is not None:
        reserve_query = reserve_query.where(CreditCardReserveEvent.credit_account_id.in_(visible_accounts))
    reserve_events = db.scalars(reserve_query.execution_options(yield_per=500))
    funded_credit_current: dict[str, int] = {}
    for event in reserve_events:
        target = activity_current if event.occurred_on >= month else activity_before
        target[event.payment_category_id] = target.get(event.payment_category_id, 0) + event.amount_minor
        if event.occurred_on >= month and event.spending_category_id is not None:
            funded_credit_current[event.spending_category_id] = funded_credit_current.get(event.spending_category_id, 0) + event.amount_minor

    rollover = cash_rollover_effects(db, budget_id, month, category_ids=visible_categories, account_ids=visible_accounts)
    rollover_by_category: dict[str, int] = {}
    for effect in rollover:
        rollover_by_category[effect.category_id] = rollover_by_category.get(effect.category_id, 0) + effect.amount_minor
    rows: list[CategoryMonthSummary] = []
    total_overspent = 0
    for category in categories:
        carried = assigned_before.get(category.id, 0) + activity_before.get(category.id, 0) + rollover_by_category.get(category.id, 0)
        assigned = assigned_current.get(category.id, 0)
        activity = activity_current.get(category.id, 0)
        available = carried + assigned + activity
        funded_credit = max(funded_credit_current.get(category.id, 0), 0)
        credit_overspent = max(-credit_activity_current.get(category.id, 0) - funded_credit, 0)
        cash_overspent = max(-available - credit_overspent, 0)
        if available < 0:
            total_overspent += -available
        category_target = targets.get(category.id)
        is_snoozed = category.id in snoozed_categories
        funding = target_funding(
            category_target,
            month=month,
            assigned_minor=assigned,
            available_minor=available,
        ) if category_target else None
        rows.append(CategoryMonthSummary(
            category_id=category.id,
            name=category.name,
            assigned_minor=assigned,
            activity_minor=activity,
            carried_available_minor=carried,
            available_minor=available,
            is_overspent=available < 0,
            target_type=category_target.target_type if category_target else None,
            target_amount_minor=category_target.target_amount_minor if category_target else None,
            target_date=funding.effective_target_date if funding else None,
            target_priority=category_target.priority if category_target else 50,
            is_target_snoozed=is_snoozed,
            recommended_contribution_minor=funding.recommended_contribution_minor if funding and not is_snoozed else 0,
            underfunded_minor=funding.underfunded_minor if funding and not is_snoozed else 0,
            cash_overspent_minor=cash_overspent,
            credit_overspent_minor=credit_overspent,
            funded_credit_spending_minor=funded_credit,
        ))
    # Household-wide spendable cash is its own permission. A resource-scoped member must not
    # infer hidden accounts or allocations even when the owner enabled that capability.
    budget_totals_visible = (
        visible_categories is None
        and visible_accounts is None
        and has_capability(db, user, budget, "view_budget_totals")
    )
    dated_unassigned = (
        unassigned_cash_to_date + ready_to_assign_postings - sum(rollover_by_category.values())
        if budget_totals_visible else 0
    )
    all_date_unassigned = (
        ready_to_assign_balance(db, budget_id)
        if budget_totals_visible and has_capability(db, user, budget, "view_account_balances") else None
    )
    return MonthSummaryResponse(
        month=month,
        currency_code=budget.currency_code,
        ready_to_assign_minor=dated_unassigned,
        budget_totals_visible=budget_totals_visible,
        all_date_unassigned_minor=all_date_unassigned,
        funding_limit_minor=(min(max(dated_unassigned, 0), max(all_date_unassigned, 0))
                             if all_date_unassigned is not None else None),
        total_assigned_minor=sum(row.assigned_minor for row in rows),
        total_overspent_minor=total_overspent,
        allocation_version=budget.allocation_version,
        categories=rows,
    )


def build_smart_funding_preview(summary: MonthSummaryResponse, *, available_minor: int | None = None) -> dict:
    # A historical month can show money that has since been assigned elsewhere. Observations
    # remain date-scoped, but a new operation may consume only still-unassigned real money.
    funding_limit = max(summary.ready_to_assign_minor, 0)
    if available_minor is not None:
        funding_limit = min(funding_limit, max(available_minor, 0))
    remaining = funding_limit
    total_need = sum(max(category.underfunded_minor, 0) for category in summary.categories)
    if total_need > MAX_INT64:
        raise HTTPException(status_code=422, detail="Combined target need exceeds the supported amount range")
    proposals = []
    for category in sorted(summary.categories, key=lambda item: (-getattr(item, "target_priority", 50), -item.recommended_contribution_minor, item.name, item.category_id)):
        requested = min(max(category.underfunded_minor, 0), remaining)
        if requested <= 0:
            continue
        if category.available_minor + requested > MAX_INT64:
            raise HTTPException(status_code=422, detail="Target funding exceeds the supported amount range")
        proposals.append({
            "category_id": category.category_id,
            "category_name": category.name,
            "amount_minor": requested,
            "before_available_minor": category.available_minor,
            "after_available_minor": category.available_minor + requested,
            "target_type": getattr(category, "target_type", None),
            "target_priority": getattr(category, "target_priority", 50),
            "recommended_contribution_minor": category.recommended_contribution_minor,
            "remaining_need_minor": max(category.underfunded_minor - requested, 0),
        })
        remaining -= requested
        if remaining == 0:
            break
    proposed = funding_limit - remaining
    amounts = {item["category_id"]: item["amount_minor"] for item in proposals}
    return {
        "month": summary.month,
        "currency_code": summary.currency_code,
        "before_ready_to_assign_minor": summary.ready_to_assign_minor,
        "proposed_minor": proposed,
        "after_ready_to_assign_minor": summary.ready_to_assign_minor - proposed,
        "allocation_version": summary.allocation_version,
        "proposals": proposals,
        "remaining_need_minor": total_need - proposed,
        "unfunded_category_count": sum(category.underfunded_minor > amounts.get(category.category_id, 0)
                                       for category in summary.categories),
        "funding_limit_minor": funding_limit,
    }


@router.get("/smart-funding/{month}", response_model=SmartFundingPreviewResponse)
def smart_funding_preview(
    budget_id: str,
    month: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    summary = month_summary(budget_id, month, user, db)
    return build_smart_funding_preview(summary, available_minor=ready_to_assign_balance(db, budget_id))


@router.post("/smart-funding", response_model=AllocationOperationResponse, status_code=status.HTTP_201_CREATED)
def commit_smart_funding(
    budget_id: str,
    body: SmartFundingCommit,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    require_budget_capability(db, user, budget_id, "assign_money")
    delegated_policy = db.scalar(select(DelegatedBudgetPolicy.id).where(
        DelegatedBudgetPolicy.budget_id == budget_id,
        DelegatedBudgetPolicy.user_id == user.id,
    ))
    if delegated_policy is not None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Delegated members allocate only from their delegated pool",
        )
    budget = lock_budget(db, budget_id)
    require_version(budget, body.expected_allocation_version)
    summary = month_summary(budget_id, body.month, user, db)
    preview = build_smart_funding_preview(summary, available_minor=ready_to_assign_balance(db, budget_id))
    if not preview["proposals"]:
        raise HTTPException(status_code=409, detail="No funded recommendations are currently available")
    total = preview["proposed_minor"]
    operation = append_operation(
        db, budget=budget, actor=user, occurred_on=body.month, kind="smart_funding",
        note=f"Funded {len(preview['proposals'])} target recommendations",
        source="smart_funding",
        postings=[PostingInput(bucket="ready_to_assign", amount_minor=-total)] + [
            PostingInput(bucket="category", category_id=item["category_id"], amount_minor=item["amount_minor"])
            for item in preview["proposals"]
        ],
    )
    db.commit()
    db.refresh(operation)
    return {
        "id": operation.id, "budget_id": operation.budget_id, "occurred_on": operation.occurred_on,
        "kind": operation.kind, "actor_user_id": operation.actor_user_id, "note": operation.note,
        "source": operation.source, "allocation_version": budget.allocation_version, "postings": operation.postings,
    }
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
    AllocationOperationResponse,
    AllocationTransferCreate,
