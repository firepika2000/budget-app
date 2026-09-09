from __future__ import annotations

import csv
import json
from datetime import date, datetime, timezone
from io import StringIO
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import StreamingResponse
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session, selectinload

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
from .dependencies import get_current_user
from .credit import add_payment_reserve_event, add_purchase_reserve_events, ensure_credit_payment_category
from .models import (
    Account,
    AllowancePlan,
    AllowanceSplit,
    AllocationOperation,
    AllocationPosting,
    Budget,
    BudgetAccessProfile,
    BudgetPermission,
    Category,
    CategoryGroup,
    CategoryTarget,
    CreditCardReserveEvent,
    DelegatedBudgetPolicy,
    DelegatedCategoryRule,
    Membership,
    ResourceGrant,
    Transaction,
    TransactionChange,
    TransactionSplit,
    User,
)
from .schemas import (
    AccountCreate,
    AccountBalanceResponse,
    AccountResponse,
    AllocationOperationResponse,
    AllocationTransferCreate,
    AssignmentResponse,
    AssignmentUpsert,
    CategoryCreate,
    CategoryDelegationUpdate,
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
    TransactionCreate,
    TransactionResponse,
    TransactionUpdate,
    TransferCreate,
    TransferResponse,
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
        "memo": transaction.memo,
        "is_cleared": transaction.is_cleared,
        "is_reconciled": transaction.is_reconciled,
        "flag": transaction.flag,
        "tags": transaction.tags,
        "attachment_metadata": transaction.attachment_metadata,
        "transfer_id": transaction.transfer_id,
        "splits": [{"category_id": item.category_id, "amount_minor": item.amount_minor, "memo": item.memo} for item in transaction.splits],
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
    } for category in categories]


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
    category = Category(budget_id=budget_id, **body.model_dump())
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
    duplicate = db.scalar(select(Category.id).where(
        Category.budget_id == budget_id,
        Category.group_id == body.group_id,
        Category.name == body.name.strip(),
        Category.id != category_id,
    ))
    if duplicate is not None:
        raise HTTPException(status_code=409, detail="A category with this name already exists in the group")
    category.group_id = body.group_id
    category.name = body.name.strip()
    category.sort_order = body.sort_order
    category.is_archived = body.is_archived
    db.commit()
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
    current_month = date.today().replace(day=1)
    if body.month > current_month:
        raise HTTPException(status_code=422, detail="Future allocations belong in the planning layer")
    budget = lock_budget(db, budget_id)
    require_version(budget, body.expected_allocation_version)
    next_month = date(
        body.month.year + (body.month.month == 12),
        1 if body.month.month == 12 else body.month.month + 1,
        1,
    )
    current_assigned = int(db.scalar(
        select(func.coalesce(func.sum(AllocationPosting.amount_minor), 0))
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(
            AllocationPosting.budget_id == budget_id,
            AllocationPosting.category_id == category_id,
            AllocationOperation.occurred_on >= body.month,
            AllocationOperation.occurred_on < next_month,
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
    operations = list(db.scalars(
        select(AllocationOperation)
        .options(selectinload(AllocationOperation.postings))
        .where(AllocationOperation.budget_id == budget_id)
        .order_by(AllocationOperation.occurred_on.desc(), AllocationOperation.created_at.desc())
    ))
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


@router.get("/transactions", response_model=list[TransactionResponse])
def list_transactions(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Transaction]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    transactions = list(db.scalars(select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget_id
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
    db.commit()
    db.refresh(transaction)
    return transaction


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
    if transaction is None or transaction.transfer_id is not None:
        raise HTTPException(status_code=404, detail="Transaction not found")
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
    if transaction is None or transaction.budget_id != budget_id or transaction.transfer_id is not None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    if transaction.is_reconciled:
        raise HTTPException(status_code=409, detail="Reconciled transactions cannot be deleted")
    if transaction.created_by_user_id != user.id and not has_capability(db, user, budget, "manage_budget_structure"):
        raise HTTPException(status_code=403, detail="You may only delete your own transactions")
    if not can_access_resource(db, user, budget, "account", transaction.account_id):
        raise HTTPException(status_code=404, detail="Transaction not found")
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
    next_month = date(month.year + (month.month == 12), 1 if month.month == 12 else month.month + 1, 1)
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
    allocation_rows = db.execute(
        select(AllocationPosting, AllocationOperation)
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(
            AllocationPosting.budget_id == budget_id,
            AllocationOperation.occurred_on < next_month,
        )
    ).all()
    transactions = list(db.scalars(select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget_id,
        Transaction.occurred_on < next_month,
    )))
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    if visible_accounts is not None:
        transactions = [transaction for transaction in transactions if transaction.account_id in visible_accounts]
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
    for posting, operation in allocation_rows:
        if posting.category_id is None:
            ready_to_assign_postings += posting.amount_minor
            continue
        target = assigned_current if operation.occurred_on >= month else assigned_before
        target[posting.category_id] = target.get(posting.category_id, 0) + posting.amount_minor

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

    reserve_events = list(db.scalars(select(CreditCardReserveEvent).where(
        CreditCardReserveEvent.budget_id == budget_id,
        CreditCardReserveEvent.occurred_on < next_month,
    )))
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
            target_date=category_target.target_date if category_target else None,
            recommended_contribution_minor=funding.recommended_contribution_minor if funding else 0,
            underfunded_minor=funding.underfunded_minor if funding else 0,
            cash_overspent_minor=cash_overspent,
            credit_overspent_minor=credit_overspent,
            funded_credit_spending_minor=funded_credit,
        ))
    return MonthSummaryResponse(
        month=month,
        currency_code=budget.currency_code,
        ready_to_assign_minor=(
            0 if visible_categories is not None else unassigned_cash_to_date + ready_to_assign_postings
        ),
        total_assigned_minor=sum(row.assigned_minor for row in rows),
        total_overspent_minor=total_overspent,
        allocation_version=budget.allocation_version,
        categories=rows,
    )


def build_smart_funding_preview(summary: MonthSummaryResponse) -> dict:
    remaining = max(summary.ready_to_assign_minor, 0)
    proposals = []
    for category in sorted(summary.categories, key=lambda item: (-item.recommended_contribution_minor, item.name)):
        requested = min(max(category.underfunded_minor, category.recommended_contribution_minor), remaining)
        if requested <= 0:
            continue
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
    proposed = summary.ready_to_assign_minor - remaining
    return {
        "month": summary.month,
        "currency_code": summary.currency_code,
        "before_ready_to_assign_minor": summary.ready_to_assign_minor,
        "proposed_minor": proposed,
        "after_ready_to_assign_minor": remaining,
        "allocation_version": summary.allocation_version,
        "proposals": proposals,
    }


@router.get("/smart-funding/{month}", response_model=SmartFundingPreviewResponse)
def smart_funding_preview(
    budget_id: str,
    month: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    return build_smart_funding_preview(month_summary(budget_id, month, user, db))


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
    summary = month_summary(budget_id, body.month, user, db)
    preview = build_smart_funding_preview(summary)
    if not preview["proposals"]:
        raise HTTPException(status_code=409, detail="No funded recommendations are currently available")
    budget = lock_budget(db, budget_id)
    require_version(budget, body.expected_allocation_version)
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
