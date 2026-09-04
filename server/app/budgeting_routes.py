import csv
from datetime import date, datetime, timezone
from io import StringIO
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import StreamingResponse
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from .access import find_visible_budget, has_budget_permission
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
from .models import (
    Account,
    AllocationOperation,
    AllocationPosting,
    Budget,
    BudgetPermission,
    Category,
    CategoryGroup,
    Transaction,
    TransactionSplit,
    User,
)
from .schemas import (
    AccountCreate,
    AccountResponse,
    AllocationOperationResponse,
    AllocationTransferCreate,
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


def safe_csv_text(value: str) -> str:
    """Prevent spreadsheet programs from treating user-entered text as a formula."""
    return f"'{value}" if value.startswith(("=", "+", "-", "@")) else value


@router.get("/export.csv")
def export_budget_csv(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> StreamingResponse:
    budget = require_budget(db, user, budget_id, BudgetPermission.VIEW)
    accounts = {
        item.id: item.name for item in db.scalars(select(Account).where(Account.budget_id == budget_id))
    }
    categories = {
        item.id: item.name for item in db.scalars(select(Category).where(Category.budget_id == budget_id))
    }
    transactions = list(db.scalars(
        select(Transaction)
        .options(selectinload(Transaction.splits))
        .where(Transaction.budget_id == budget_id)
        .order_by(Transaction.occurred_on, Transaction.created_at, Transaction.id)
    ))
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
) -> dict:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id:
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
    budget = require_budget(db, user, budget_id, BudgetPermission.VIEW)
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
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
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
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transactions belong in the planning layer")
    account = db.get(Account, body.account_id)
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid account")
    category_ids = ([body.category_id] if body.category_id is not None else []) + [
        split.category_id for split in body.splits
    ]
    if category_ids and not account.is_on_budget:
        raise HTTPException(status_code=422, detail="Tracking accounts cannot affect budget categories")
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
    if body.occurred_on > date.today():
        raise HTTPException(status_code=422, detail="Future transfers belong in the planning layer")
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
    on_budget_account_ids = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
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
    unassigned_cash_to_date = 0
    for transaction in transactions:
        if (
            transaction.account_id in on_budget_account_ids
            and transaction.transfer_id is None
            and transaction.category_id is None
            and not transaction.splits
        ):
            unassigned_cash_to_date += transaction.amount_minor
        if transaction.account_id not in on_budget_account_ids:
            continue
        target = activity_current if transaction.occurred_on >= month else activity_before
        if transaction.category_id is not None:
            target[transaction.category_id] = target.get(transaction.category_id, 0) + transaction.amount_minor
        for split in transaction.splits:
            target[split.category_id] = target.get(split.category_id, 0) + split.amount_minor

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
        ready_to_assign_minor=unassigned_cash_to_date + ready_to_assign_postings,
        total_assigned_minor=sum(assigned_current.values()),
        total_overspent_minor=total_overspent,
        allocation_version=budget.allocation_version,
        categories=rows,
    )
    MonthSummaryResponse,
    ReconcileRequest,
    ReconcileResponse,
    AllocationOperationResponse,
    AllocationTransferCreate,
