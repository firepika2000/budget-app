from __future__ import annotations

import csv
import base64
import json
from datetime import date, datetime, timezone, timedelta
import hashlib
from io import StringIO
from typing import Optional
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Query, Request, status
from fastapi.responses import Response, StreamingResponse
from .schemas import MAX_INT64
from .calendar_dates import month_end
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
)
from .dependencies import get_current_user
from .credit import add_payment_reserve_event, add_purchase_reserve_events, ensure_credit_payment_category
from .category_names import normalized_category_name
from .models import (
    Account,
    AccountDebtTerms,
    AllowancePlan,
    AllowanceSplit,
    AllocationOperation,
    AllocationPosting,
    Budget,
    BudgetAccessProfile,
    BudgetPermission,
    Category,
    CategoryFavorite,
    CategoryGroup,
    CategoryTarget,
    CategoryTargetSnooze,
    CreditCardReserveEvent,
    DelegatedBudgetPolicy,
    DelegatedCategoryRule,
    Membership,
    Payee,
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
    AccountDebtTermsUpsert,
    DebtProjectionRequest,
    DebtProjectionResponse,
    DebtStrategyProjectionRequest,
    DebtStrategyProjectionResponse,
    AccountResponse,
    AllocationOperationResponse,
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
    CategoryMonthSummary,
    CategoryResponse,
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
    SmartFundingCommit,
    SmartFundingPreviewResponse,
    ScheduledTransactionResponse,
    TransactionBulkUpdateRequest,
    TransactionCreate,
    TransactionDuplicateRequest,
    TransactionVoidRequest,
    TransactionScheduleRequest,
    TransactionAttachmentResponse,
    TransactionPageResponse,
    TransactionResponse,
    TransactionUpdate,
    TransferCreate,
    TransferResponse,
)
from .models import ScheduledTransaction
from .planning import next_occurrence
from .attachment_storage import AttachmentStorage, safe_filename, validate_content

ON_BUDGET_CASH_TYPES = {"checking", "savings", "cash"}
TRACKING_TYPES = {"loan", "tracking"}


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
            detail="Choose a budget account type for On budget, or Loan/Tracking for Tracking.",
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
    if body.starting_balance_minor:
        db.add(Transaction(
            budget_id=budget_id,
            account_id=account.id,
            category_id=None,
            amount_minor=body.starting_balance_minor,
            occurred_on=date.today(),
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
    validate_account_type_transition(account, body.account_type)
    account.name = body.name.strip()
    if not account.name:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="Enter an account name.")
    account.account_type = body.account_type
    if account.account_type == "credit" and account.payment_category_id:
        payment_category = db.get(Category, account.payment_category_id)
        if payment_category is not None and payment_category.system_type == "credit_payment":
            payment_category.name = f"{account.name} Payment"
            payment_category.name_key = normalized_category_name(payment_category.name)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    db.refresh(account)
    return account


@router.get("/accounts/{account_id}/debt-terms", response_model=Optional[AccountDebtTermsResponse])
def get_account_debt_terms(
    budget_id: str,
    account_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan"} or not can_access_resource(
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
        else "installment_loan" if account.account_type == "loan"
        else None
    )
    if expected_type is None:
        raise HTTPException(status_code=422, detail="Debt terms are available only for credit cards and loans")
    if body.terms_type != expected_type:
        raise HTTPException(status_code=422, detail=f"Use {expected_type} terms for this account")
    values = body.model_dump()
    terms = db.get(AccountDebtTerms, account_id)
    if terms is None:
        terms = AccountDebtTerms(account_id=account_id, budget_id=budget_id, **values)
        db.add(terms)
    else:
        for name, value in values.items():
            setattr(terms, name, value)
        terms.updated_at = datetime.now(timezone.utc)
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
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan"} or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=404, detail="Account not found")
    terms = db.get(AccountDebtTerms, account_id)
    if terms is not None:
        db.delete(terms)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


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
    if account is None or account.budget_id != budget_id or account.account_type not in {"credit", "loan"} or not can_access_resource(
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
        Account.account_type.in_(("credit", "loan")),
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
    }


@router.get("/accounts/{account_id}/balance", response_model=AccountBalanceResponse)
def account_balance(
    budget_id: str,
    account_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AccountBalanceResponse:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    cleared = int(db.scalar(select(
        func.coalesce(func.sum(Transaction.amount_minor), 0)
    ).where(Transaction.account_id == account_id, Transaction.is_cleared.is_(True))) or 0)
    uncleared = int(db.scalar(select(
        func.coalesce(func.sum(Transaction.amount_minor), 0)
    ).where(Transaction.account_id == account_id, Transaction.is_cleared.is_(False))) or 0)
    return AccountBalanceResponse(
        account_id=account.id,
        currency_code=budget.currency_code,
        cleared_balance_minor=cleared,
        uncleared_balance_minor=uncleared,
        working_balance_minor=cleared + uncleared,
        reconciled_balance_minor=account.reconciled_balance_minor,
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
    db.commit()
    db.refresh(group)
    return group


@router.put("/category-groups/{group_id}", response_model=CategoryGroupResponse)
def update_category_group(budget_id: str, group_id: str, body: CategoryGroupUpdate, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> CategoryGroup:
    require_budget_capability(db, user, budget_id, "manage_budget_structure")
    group = db.get(CategoryGroup, group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=404, detail="Category group not found")
    group.name = body.name.strip(); group.sort_order = body.sort_order; group.is_archived = body.is_archived
    db.commit(); db.refresh(group); return group


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
        "sort_order": category.sort_order,
        "is_archived": category.is_archived,
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
        "name": category.name, "sort_order": category.sort_order, "is_archived": category.is_archived,
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
    category.delegated_user_id = body.delegated_user_id
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
    category.sort_order = body.sort_order
    category.is_archived = body.is_archived
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    db.refresh(category)
    return category


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
    db.commit()
    return {
        "budget_id": budget_id,
        "category_id": category_id,
        "month": body.month,
        "assigned_minor": body.assigned_minor,
        "allocation_version": budget.allocation_version,
    }


@router.get("/allocations", response_model=list[AllocationOperationResponse])
def list_allocation_operations(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_allocation_history")
    query = (
        select(AllocationOperation)
        .options(selectinload(AllocationOperation.postings))
        .where(AllocationOperation.budget_id == budget_id)
        .order_by(AllocationOperation.occurred_on.desc(), AllocationOperation.created_at.desc(), AllocationOperation.id)
    )
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_categories is not None:
        if not visible_categories:
            return []
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
    operations = list(db.scalars(query))
    return [{
        "id": operation.id,
        "budget_id": operation.budget_id,
        "occurred_on": operation.occurred_on,
        "kind": operation.kind,
        "actor_user_id": operation.actor_user_id,
        "note": operation.note,
        "source": operation.source,
        "allocation_version": budget.allocation_version,
        "postings": operation.postings,
    } for operation in operations]


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
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
    budget = lock_budget(db, budget_id)
    require_version(budget, body.expected_allocation_version)
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
    db.commit()
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

    conditions = [Transaction.budget_id == budget.id]
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_accounts is not None:
        conditions.append(Transaction.account_id.in_(visible_accounts) if visible_accounts else false())
    if visible_categories is not None:
        if visible_categories:
            conditions.append(or_(
                Transaction.category_id.in_(visible_categories),
                and_(
                    Transaction.category_id.is_(None),
                    Transaction.splits.any(),
                    ~Transaction.splits.any(~TransactionSplit.category_id.in_(visible_categories)),
                ),
            ))
        else:
            conditions.append(false())
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
) -> list[Transaction]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    return _visible_transactions(db, user, budget)


@router.post("/transactions", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def create_transaction(
    budget_id: str,
    body: TransactionCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transactions belong in the planning layer")
    account = db.scalar(select(Account).where(Account.id == body.account_id).with_for_update())
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid account")
    if (body.financial_classification is not None or any(split.financial_classification is not None for split in body.splits)) and account.account_type not in {"credit", "loan"}:
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
    db.commit()
    db.refresh(transaction)
    return transaction


@router.post("/transactions/bulk", response_model=list[TransactionResponse])
def bulk_update_transactions(
    budget_id: str,
    body: TransactionBulkUpdateRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Transaction]:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id, Transaction.id.in_(body.transaction_ids),
    ).with_for_update()))
    if len(transactions) != len(body.transaction_ids):
        raise HTTPException(status_code=404, detail="One or more transactions were not found")
    for transaction in transactions:
        if not _can_access_transaction_resources(db, user, budget, transaction):
            raise HTTPException(status_code=404, detail="One or more transactions were not found")
        if transaction.status != "posted":
            raise HTTPException(status_code=409, detail="Voided and reversal transactions are immutable")
        if transaction.is_reconciled:
            raise HTTPException(status_code=409, detail="Reconciled transactions cannot be changed in bulk")
        if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
            raise HTTPException(status_code=403, detail="You may only edit your own transactions")
        if transaction.transfer_id is not None or transaction.scheduled_transaction_id is not None or transaction.payee_name in {"Starting Balance", "Reconciliation adjustment"}:
            raise HTTPException(status_code=409, detail="System-linked transactions must be changed through their specialized workflow")

    by_id = {transaction.id: transaction for transaction in transactions}
    ordered = [by_id[transaction_id] for transaction_id in body.transaction_ids]
    for transaction in ordered:
        before = transaction_snapshot(transaction)
        if body.action == "set_cleared":
            transaction.is_cleared = bool(body.cleared)
        elif body.action == "set_flag":
            transaction.flag = body.flag
        elif body.action == "add_tags":
            transaction.tags = list(dict.fromkeys([*transaction.tags, *body.tags]))[:20]
        else:
            removed = set(body.tags)
            transaction.tags = [tag for tag in transaction.tags if tag not in removed]
        record_transaction_change(db, transaction, user, "bulk_updated", before=before, after=transaction_snapshot(transaction))
    db.commit()
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
    original = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id, Transaction.budget_id == budget_id,
    ).with_for_update())
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
        budget_id=budget_id, account_id=original.account_id, category_id=original.category_id,
        payee_id=original.payee_id, amount_minor=-original.amount_minor, occurred_on=now.date(),
        payee_name=f"Reversal: {original.payee_name or 'Transaction'}"[:150],
        memo=(f"Void reversal. {body.reason}" if body.reason else "Void reversal.")[:500],
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
    original.void_reason = body.reason or None
    original.reversal_transaction_id = reversal.id
    record_transaction_change(db, original, user, "voided", before=before_snapshot, after=transaction_snapshot(original))
    record_transaction_change(db, reversal, user, "reversal_created", after=transaction_snapshot(reversal))
    db.commit()
    db.refresh(reversal)
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
    while next_date is not None and next_date <= date.today():
        next_date = next_occurrence(next_date, body.recurrence_unit, body.interval_count)
    if next_date is None or next_date <= date.today():
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
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    transaction = db.scalar(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.id == transaction_id,
        Transaction.budget_id == budget_id,
    ).with_for_update())
    if transaction is None or transaction.transfer_id is not None or not _can_access_transaction_resources(db, user, budget, transaction):
        raise HTTPException(status_code=404, detail="Transaction not found")
    if transaction.status != "posted":
        raise HTTPException(status_code=409, detail="Voided and reversal transactions are immutable")
    if transaction.is_reconciled:
        raise HTTPException(status_code=409, detail="Reconciled transactions cannot be edited")
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only edit your own transactions")
    before_snapshot = transaction_snapshot(transaction)
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transactions belong in the planning layer")
    account = db.scalar(select(Account).where(Account.id == body.account_id).with_for_update())
    if account is None or account.budget_id != budget_id or account.is_closed or not can_access_resource(db, user, budget, "account", account.id):
        raise HTTPException(status_code=422, detail="Invalid account")
    if (body.financial_classification is not None or any(split.financial_classification is not None for split in body.splits)) and account.account_type not in {"credit", "loan"}:
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
    db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.source_transaction_id == transaction.id))
    values = body.model_dump(exclude={"splits"})
    for key, value in values.items():
        setattr(transaction, key, value)
    transaction.splits = [TransactionSplit(**split.model_dump()) for split in body.splits]
    db.flush()
    category_amounts = (
        [(categories_by_id[body.category_id], body.amount_minor)]
        if body.category_id is not None else [(categories_by_id[split.category_id], split.amount_minor) for split in body.splits]
    )
    add_purchase_reserve_events(db, account=account, transaction=transaction, category_amounts=category_amounts, actor=user)
    record_transaction_change(db, transaction, user, "updated", before=before_snapshot, after=transaction_snapshot(transaction))
    db.commit()
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
    body: TransferCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransferResponse:
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    if body.occurred_on > date.today():
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
    db.commit()
    db.refresh(source_transaction)
    db.refresh(destination_transaction)
    return TransferResponse(
        transfer_id=transfer_id,
        source=TransactionResponse.model_validate(source_transaction),
        destination=TransactionResponse.model_validate(destination_transaction),
    )


def _locked_transfer_legs(db: Session, budget_id: str, transfer_id: str) -> list[Transaction]:
    legs = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id,
        Transaction.transfer_id == transfer_id,
    ).order_by(Transaction.id).with_for_update()))
    if len(legs) != 2 or sum(leg.amount_minor for leg in legs) != 0:
        raise HTTPException(status_code=404, detail="Transfer not found")
    return legs


def _authorize_transfer_legs(db: Session, user: User, budget: Budget, legs: list[Transaction], action: str) -> None:
    if any(not can_access_resource(db, user, budget, "account", leg.account_id) for leg in legs):
        raise HTTPException(status_code=404, detail="Transfer not found")
    if any(leg.created_by_user_id != user.id for leg in legs) and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail=f"You may only {action} your own transfers")
    if any(leg.is_reconciled for leg in legs):
        consequence = "modified" if action == "edit" else "deleted"
        raise HTTPException(status_code=409, detail=f"Reconciled transfers cannot be {consequence}")


@router.put("/transfers/{transfer_id}", response_model=TransferResponse)
def update_transfer(
    budget_id: str,
    transfer_id: str,
    body: TransferCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransferResponse:
    budget = require_budget_capability(db, user, budget_id, "edit_transaction")
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
    legs = _locked_transfer_legs(db, budget_id, transfer_id)
    _authorize_transfer_legs(db, user, budget, legs, "edit")
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
    common = {"occurred_on": body.occurred_on, "memo": body.memo, "is_cleared": body.is_cleared}
    for key, value in common.items():
        setattr(source_leg, key, value); setattr(destination_leg, key, value)
    source_leg.account_id = body.source_account_id; source_leg.amount_minor = -body.amount_minor
    destination_leg.account_id = body.destination_account_id; destination_leg.amount_minor = body.amount_minor
    db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.transfer_id == transfer_id))
    if destination.account_type == "credit":
        add_payment_reserve_event(db, credit_account=destination, transfer_id=transfer_id, occurred_on=body.occurred_on, amount_minor=-body.amount_minor, actor=user, kind="payment")
    elif source.account_type == "credit":
        add_payment_reserve_event(db, credit_account=source, transfer_id=transfer_id, occurred_on=body.occurred_on, amount_minor=body.amount_minor, actor=user, kind="payment_reversal")
    for leg in legs:
        record_transaction_change(db, leg, user, "updated", before=before[leg.id], after=transaction_snapshot(leg))
    db.commit(); db.refresh(source_leg); db.refresh(destination_leg)
    return TransferResponse(transfer_id=transfer_id, source=TransactionResponse.model_validate(source_leg), destination=TransactionResponse.model_validate(destination_leg))


@router.delete("/transfers/{transfer_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_transfer(
    budget_id: str,
    transfer_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "delete_transaction")
    legs = _locked_transfer_legs(db, budget_id, transfer_id)
    _authorize_transfer_legs(db, user, budget, legs, "delete")
    for leg in legs:
        record_transaction_change(db, leg, user, "deleted", before=transaction_snapshot(leg))
    db.execute(delete(CreditCardReserveEvent).where(CreditCardReserveEvent.transfer_id == transfer_id))
    for leg in legs:
        db.delete(leg)
    db.commit()


@router.post("/accounts/{account_id}/reconcile", response_model=ReconcileResponse)
def reconcile_account(
    budget_id: str,
    account_id: str,
    body: ReconcileRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReconcileResponse:
    budget = require_budget_capability(db, user, budget_id, "reconcile_account")
    account = db.scalar(select(Account).where(Account.id == account_id).with_for_update())
    if account is None or account.budget_id != budget_id or not can_access_resource(
        db, user, budget, "account", account_id
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    transactions = list(db.scalars(select(Transaction).where(
        Transaction.account_id == account_id,
        Transaction.occurred_on <= body.through_date,
        Transaction.is_cleared.is_(True),
    )))
    cleared_balance = sum(transaction.amount_minor for transaction in transactions)
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
        transactions.append(adjustment_transaction)
    newly_reconciled = 0
    for transaction in transactions:
        if not transaction.is_reconciled:
            transaction.is_reconciled = True
            newly_reconciled += 1
    account.reconciled_balance_minor = body.statement_balance_minor
    account.reconciled_at = datetime.now(timezone.utc)
    db.commit()
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

    reserve_events = db.scalars(select(CreditCardReserveEvent).where(
        CreditCardReserveEvent.budget_id == budget_id,
        CreditCardReserveEvent.occurred_on <= through,
    ).execution_options(yield_per=500))
    funded_credit_current: dict[str, int] = {}
    for event in reserve_events:
        target = activity_current if event.occurred_on >= month else activity_before
        target[event.payment_category_id] = target.get(event.payment_category_id, 0) + event.amount_minor
        if event.occurred_on >= month and event.spending_category_id is not None:
            funded_credit_current[event.spending_category_id] = funded_credit_current.get(event.spending_category_id, 0) + event.amount_minor

    rows: list[CategoryMonthSummary] = []
    total_overspent = 0
    for category in categories:
        carried = assigned_before.get(category.id, 0) + activity_before.get(category.id, 0)
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
    # A scoped household view cannot derive global spendable cash from its visible subset.
    # Omit these observations rather than leak hidden accounts/allocations or invent a balance.
    dated_unassigned = 0 if visible_categories is not None else unassigned_cash_to_date + ready_to_assign_postings
    all_date_unassigned = (
        ready_to_assign_balance(db, budget_id)
        if visible_categories is None and visible_accounts is None
        and has_capability(db, user, budget, "view_account_balances") else None
    )
    return MonthSummaryResponse(
        month=month,
        currency_code=budget.currency_code,
        ready_to_assign_minor=dated_unassigned,
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
