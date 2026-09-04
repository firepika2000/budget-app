from datetime import date, datetime, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from .access import find_visible_budget, has_budget_permission
from .database import get_db
from .dependencies import get_current_user
from .models import (
    Account,
    Budget,
    BudgetPermission,
    Category,
    CategoryGroup,
    MonthlyAssignment,
    Transaction,
    TransactionSplit,
    User,
)
from .schemas import (
    AccountCreate,
    AccountResponse,
    AssignmentResponse,
    AssignmentUpsert,
    CategoryCreate,
    CategoryGroupCreate,
    CategoryGroupResponse,
    CategoryMonthSummary,
    CategoryResponse,
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
    TransactionCreate,
    TransactionResponse,
    TransferCreate,
    TransferResponse,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


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


@router.get("/accounts", response_model=list[AccountResponse])
def list_accounts(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Account]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Account).where(Account.budget_id == budget_id).order_by(Account.name)))


@router.post("/accounts", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(
    budget_id: str,
    body: AccountCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    account = Account(budget_id=budget_id, **body.model_dump())
    db.add(account)
    db.commit()
    db.refresh(account)
    return account


@router.get("/category-groups", response_model=list[CategoryGroupResponse])
def list_category_groups(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[CategoryGroup]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(CategoryGroup).where(
        CategoryGroup.budget_id == budget_id
    ).order_by(CategoryGroup.sort_order, CategoryGroup.name)))


@router.post("/category-groups", response_model=CategoryGroupResponse, status_code=status.HTTP_201_CREATED)
def create_category_group(
    budget_id: str,
    body: CategoryGroupCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CategoryGroup:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    group = CategoryGroup(budget_id=budget_id, **body.model_dump())
    db.add(group)
    db.commit()
    db.refresh(group)
    return group


@router.get("/categories", response_model=list[CategoryResponse])
def list_categories(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Category]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Category).where(
        Category.budget_id == budget_id
    ).order_by(Category.group_id, Category.sort_order, Category.name)))


@router.post("/categories", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
def create_category(
    budget_id: str,
    body: CategoryCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Category:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    group = db.get(CategoryGroup, body.group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=422, detail="Invalid category group")
    category = Category(budget_id=budget_id, **body.model_dump())
    db.add(category)
    db.commit()
    db.refresh(category)
    return category


@router.put("/categories/{category_id}/assignment", response_model=AssignmentResponse)
def upsert_assignment(
    budget_id: str,
    category_id: str,
    body: AssignmentUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MonthlyAssignment:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Category not found")
    assignment = db.scalar(select(MonthlyAssignment).where(
        MonthlyAssignment.category_id == category_id,
        MonthlyAssignment.month == body.month,
    ))
    if assignment is None:
        assignment = MonthlyAssignment(
            budget_id=budget_id,
            category_id=category_id,
            month=body.month,
            assigned_minor=body.assigned_minor,
        )
        db.add(assignment)
    else:
        assignment.assigned_minor = body.assigned_minor
    db.commit()
    db.refresh(assignment)
    return assignment


@router.get("/transactions", response_model=list[TransactionResponse])
def list_transactions(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Transaction]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget_id
    ).order_by(Transaction.occurred_on.desc(), Transaction.created_at.desc())))


@router.post("/transactions", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def create_transaction(
    budget_id: str,
    body: TransactionCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    require_budget(db, user, budget_id, BudgetPermission.CONTRIBUTE)
    account = db.get(Account, body.account_id)
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid account")
    category_ids = ([body.category_id] if body.category_id is not None else []) + [
        split.category_id for split in body.splits
    ]
    if len(category_ids) != len(set(category_ids)):
        raise HTTPException(status_code=422, detail="Duplicate split category")
    for category_id in category_ids:
        category = db.get(Category, category_id)
        if category is None or category.budget_id != budget_id or category.is_archived:
            raise HTTPException(status_code=422, detail="Invalid category")
    transaction_values = body.model_dump(exclude={"splits"})
    transaction = Transaction(
        budget_id=budget_id,
        created_by_user_id=user.id,
        **transaction_values,
    )
    transaction.splits = [TransactionSplit(**split.model_dump()) for split in body.splits]
    db.add(transaction)
    db.commit()
    db.refresh(transaction)
    return transaction


@router.post("/transfers", response_model=TransferResponse, status_code=status.HTTP_201_CREATED)
def create_transfer(
    budget_id: str,
    body: TransferCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TransferResponse:
    require_budget(db, user, budget_id, BudgetPermission.CONTRIBUTE)
    source = db.get(Account, body.source_account_id)
    destination = db.get(Account, body.destination_account_id)
    if any(
        account is None or account.budget_id != budget_id or account.is_closed
        for account in (source, destination)
    ):
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
    db.commit()
    db.refresh(source_transaction)
    db.refresh(destination_transaction)
    return TransferResponse(
        transfer_id=transfer_id,
        source=TransactionResponse.model_validate(source_transaction),
        destination=TransactionResponse.model_validate(destination_transaction),
    )


@router.post("/accounts/{account_id}/reconcile", response_model=ReconcileResponse)
def reconcile_account(
    budget_id: str,
    account_id: str,
    body: ReconcileRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReconcileResponse:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    account = db.get(Account, account_id)
    if account is None or account.budget_id != budget_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    transactions = list(db.scalars(select(Transaction).where(
        Transaction.account_id == account_id,
        Transaction.occurred_on <= body.through_date,
        Transaction.is_cleared.is_(True),
    )))
    cleared_balance = sum(transaction.amount_minor for transaction in transactions)
    if cleared_balance != body.statement_balance_minor:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": "Cleared balance does not match statement",
                "cleared_balance_minor": cleared_balance,
            },
        )
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
    )


@router.get("/months/{month}", response_model=MonthSummaryResponse)
def month_summary(
    budget_id: str,
    month: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MonthSummaryResponse:
    budget = require_budget(db, user, budget_id, BudgetPermission.VIEW)
    if month.day != 1:
        raise HTTPException(status_code=422, detail="Month must be the first day of a month")
    next_month = date(month.year + (month.month == 12), 1 if month.month == 12 else month.month + 1, 1)
    categories = list(db.scalars(select(Category).where(
        Category.budget_id == budget_id,
        Category.is_archived.is_(False),
    ).order_by(Category.group_id, Category.sort_order, Category.name)))
    assignments = list(db.scalars(select(MonthlyAssignment).where(
        MonthlyAssignment.budget_id == budget_id,
        MonthlyAssignment.month < next_month,
    )))
    transactions = list(db.scalars(select(Transaction).options(
        selectinload(Transaction.splits)
    ).where(
        Transaction.budget_id == budget_id,
        Transaction.occurred_on < next_month,
    )))
    on_budget_account_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
    )))

    assigned_before: dict[str, int] = {}
    assigned_current: dict[str, int] = {}
    for assignment in assignments:
        target = assigned_current if assignment.month == month else assigned_before
        target[assignment.category_id] = target.get(assignment.category_id, 0) + assignment.assigned_minor

    activity_before: dict[str, int] = {}
    activity_current: dict[str, int] = {}
    unassigned_cash_to_date = 0
    for transaction in transactions:
        if (
            transaction.account_id in on_budget_account_ids
            and transaction.transfer_id is None
            and transaction.category_id is None
            and not transaction.splits
        ):
            unassigned_cash_to_date += transaction.amount_minor
        target = activity_current if transaction.occurred_on >= month else activity_before
        if transaction.category_id is not None:
            target[transaction.category_id] = target.get(transaction.category_id, 0) + transaction.amount_minor
        for split in transaction.splits:
            target[split.category_id] = target.get(split.category_id, 0) + split.amount_minor

    all_assigned = sum(assignment.assigned_minor for assignment in assignments)
    rows: list[CategoryMonthSummary] = []
    total_overspent = 0
    for category in categories:
        carried = assigned_before.get(category.id, 0) + activity_before.get(category.id, 0)
        assigned = assigned_current.get(category.id, 0)
        activity = activity_current.get(category.id, 0)
        available = carried + assigned + activity
        if available < 0:
            total_overspent += -available
        rows.append(CategoryMonthSummary(
            category_id=category.id,
            name=category.name,
            assigned_minor=assigned,
            activity_minor=activity,
            carried_available_minor=carried,
            available_minor=available,
            is_overspent=available < 0,
        ))
    return MonthSummaryResponse(
        month=month,
        currency_code=budget.currency_code,
        ready_to_assign_minor=unassigned_cash_to_date - all_assigned,
        total_assigned_minor=sum(assigned_current.values()),
        total_overspent_minor=total_overspent,
        categories=rows,
    )
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
