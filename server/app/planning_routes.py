from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .budgeting_routes import require_budget
from .database import get_db
from .dependencies import get_current_user
from .models import (
    Account,
    BudgetPermission,
    Category,
    CategoryTarget,
    ScheduledTransaction,
    Transaction,
    User,
)
from .planning import occurrences_between
from .schemas import (
    CategoryTargetResponse,
    CategoryTargetUpsert,
    ForecastAccountBalance,
    ForecastOccurrence,
    ForecastResponse,
    ScheduledTransactionCreate,
    ScheduledTransactionResponse,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


@router.put(
    "/categories/{category_id}/target",
    response_model=CategoryTargetResponse,
)
def upsert_category_target(
    budget_id: str,
    category_id: str,
    body: CategoryTargetUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CategoryTarget:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id or category.is_archived:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Category not found")
    target = db.scalar(select(CategoryTarget).where(CategoryTarget.category_id == category_id))
    values = body.model_dump()
    if target is None:
        target = CategoryTarget(
            budget_id=budget_id,
            category_id=category_id,
            created_by_user_id=user.id,
            **values,
        )
        db.add(target)
    else:
        for field, value in values.items():
            setattr(target, field, value)
    db.commit()
    db.refresh(target)
    return target


@router.get("/categories/{category_id}/target", response_model=CategoryTargetResponse)
def get_category_target(
    budget_id: str,
    category_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CategoryTarget:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    target = db.scalar(select(CategoryTarget).where(
        CategoryTarget.budget_id == budget_id,
        CategoryTarget.category_id == category_id,
    ))
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Target not found")
    return target


@router.get("/scheduled-transactions", response_model=list[ScheduledTransactionResponse])
def list_scheduled_transactions(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ScheduledTransaction]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(ScheduledTransaction).where(
        ScheduledTransaction.budget_id == budget_id,
        ScheduledTransaction.is_active.is_(True),
    ).order_by(ScheduledTransaction.next_date, ScheduledTransaction.name)))


@router.post(
    "/scheduled-transactions",
    response_model=ScheduledTransactionResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_scheduled_transaction(
    budget_id: str,
    body: ScheduledTransactionCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ScheduledTransaction:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    account = db.get(Account, body.account_id)
    destination = db.get(Account, body.destination_account_id) if body.destination_account_id else None
    category = db.get(Category, body.category_id) if body.category_id else None
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid scheduled account")
    if body.destination_account_id and (
        destination is None or destination.budget_id != budget_id or destination.is_closed
    ):
        raise HTTPException(status_code=422, detail="Invalid scheduled destination account")
    if body.category_id and (
        category is None or category.budget_id != budget_id or category.is_archived
    ):
        raise HTTPException(status_code=422, detail="Invalid scheduled category")
    if category is not None and not account.is_on_budget:
        raise HTTPException(status_code=422, detail="Tracking accounts cannot affect budget categories")
    schedule = ScheduledTransaction(
        budget_id=budget_id,
        created_by_user_id=user.id,
        **body.model_dump(),
    )
    db.add(schedule)
    db.commit()
    db.refresh(schedule)
    return schedule


@router.get("/forecast", response_model=ForecastResponse)
def forecast(
    budget_id: str,
    through: date = Query(...),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ForecastResponse:
    budget = require_budget(db, user, budget_id, BudgetPermission.VIEW)
    today = date.today()
    if through < today or through > today + timedelta(days=366):
        raise HTTPException(status_code=422, detail="Forecast horizon must be between today and one year")
    accounts = list(db.scalars(select(Account).where(
        Account.budget_id == budget_id,
    ).order_by(Account.name)))
    accounts_by_id = {account.id: account for account in accounts}
    actual_by_account = {account.id: int(db.scalar(
        select(func.coalesce(func.sum(Transaction.amount_minor), 0)).where(
            Transaction.account_id == account.id
        )
    ) or 0) for account in accounts}
    projected = dict(actual_by_account)
    schedules = list(db.scalars(select(ScheduledTransaction).where(
        ScheduledTransaction.budget_id == budget_id,
        ScheduledTransaction.is_active.is_(True),
    )))
    occurrences: list[ForecastOccurrence] = []
    expanded: list[tuple[date, ScheduledTransaction]] = []
    for schedule in schedules:
        if accounts_by_id[schedule.account_id].is_closed or (
            schedule.destination_account_id is not None
            and accounts_by_id[schedule.destination_account_id].is_closed
        ):
            continue
        expanded.extend((occurrence, schedule) for occurrence in occurrences_between(
            schedule, today, through
        ))
    expanded.sort(key=lambda item: (item[0], item[1].id))
    on_budget_ids = {account.id for account in accounts if account.is_on_budget}
    running_total = sum(projected[account_id] for account_id in on_budget_ids)
    lowest_total = running_total
    for occurrence_date, schedule in expanded:
        if schedule.destination_account_id is None:
            projected[schedule.account_id] += schedule.amount_minor
        else:
            projected[schedule.account_id] -= schedule.amount_minor
            projected[schedule.destination_account_id] += schedule.amount_minor
        running_total = sum(projected[account_id] for account_id in on_budget_ids)
        lowest_total = min(lowest_total, running_total)
        occurrences.append(ForecastOccurrence(
            scheduled_transaction_id=schedule.id,
            name=schedule.name,
            occurred_on=occurrence_date,
            account_id=schedule.account_id,
            destination_account_id=schedule.destination_account_id,
            category_id=schedule.category_id,
            amount_minor=schedule.amount_minor,
        ))
    return ForecastResponse(
        as_of=today,
        through=through,
        currency_code=budget.currency_code,
        actual_total_on_budget_minor=sum(actual_by_account[item] for item in on_budget_ids),
        projected_total_on_budget_minor=sum(projected[item] for item in on_budget_ids),
        lowest_projected_total_minor=lowest_total,
        accounts=[ForecastAccountBalance(
            account_id=account.id,
            name=account.name,
            actual_balance_minor=actual_by_account[account.id],
            projected_balance_minor=projected[account.id],
        ) for account in accounts],
        occurrences=occurrences,
    )
