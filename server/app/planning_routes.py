from datetime import date, timedelta
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .access import can_access_resource, visible_resource_ids
from .budgeting_routes import require_budget_capability
from .credit import add_payment_reserve_event, add_purchase_reserve_events
from .database import get_db
from .dependencies import get_current_user
from .models import (
    Account,
    Category,
    CategoryTarget,
    ScheduledTransaction,
    Transaction,
    User,
)
from .planning import next_occurrence, occurrences_between
from .schemas import (
    CategoryTargetResponse,
    CategoryTargetUpsert,
    ForecastAccountBalance,
    ForecastOccurrence,
    ForecastResponse,
    ScheduledRealizationResponse,
    ScheduledTransactionCreate,
    ScheduledTransactionResponse,
    ScheduledTransactionUpdate,
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
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    category = db.get(Category, category_id)
    if (
        category is None or category.budget_id != budget_id or category.is_archived
        or not can_access_resource(db, user, budget, "category", category_id)
    ):
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
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    if not can_access_resource(db, user, budget, "category", category_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Target not found")
    target = db.scalar(select(CategoryTarget).where(
        CategoryTarget.budget_id == budget_id,
        CategoryTarget.category_id == category_id,
    ))
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Target not found")
    return target


@router.delete("/categories/{category_id}/target", status_code=status.HTTP_204_NO_CONTENT)
def delete_category_target(
    budget_id: str,
    category_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    category = db.get(Category, category_id)
    if (
        category is None or category.budget_id != budget_id
        or not can_access_resource(db, user, budget, "category", category_id)
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Target not found")
    target = db.scalar(select(CategoryTarget).where(
        CategoryTarget.budget_id == budget_id,
        CategoryTarget.category_id == category_id,
    ))
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Target not found")
    # Targets are planning metadata only. Removing one deletes no allocations or transactions
    # and moves no money; recommendations simply stop being produced for the category.
    db.delete(target)
    db.commit()


@router.get("/scheduled-transactions", response_model=list[ScheduledTransactionResponse])
def list_scheduled_transactions(
    budget_id: str,
    include_inactive: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ScheduledTransaction]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    query = select(ScheduledTransaction).where(ScheduledTransaction.budget_id == budget_id)
    if not include_inactive:
        query = query.where(ScheduledTransaction.is_active.is_(True))
    schedules = list(db.scalars(query.order_by(ScheduledTransaction.next_date, ScheduledTransaction.name)))
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    return [item for item in schedules if (
        (visible_accounts is None or item.account_id in visible_accounts)
        and (item.destination_account_id is None or visible_accounts is None or item.destination_account_id in visible_accounts)
        and (item.category_id is None or visible_categories is None or item.category_id in visible_categories)
    )]


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
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    account = db.get(Account, body.account_id)
    destination = db.get(Account, body.destination_account_id) if body.destination_account_id else None
    category = db.get(Category, body.category_id) if body.category_id else None
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid scheduled account")
    if not can_access_resource(db, user, budget, "account", account.id):
        raise HTTPException(status_code=422, detail="Invalid scheduled account")
    if body.destination_account_id and (
        destination is None or destination.budget_id != budget_id or destination.is_closed
        or not can_access_resource(db, user, budget, "account", destination.id)
    ):
        raise HTTPException(status_code=422, detail="Invalid scheduled destination account")
    if body.category_id and (
        category is None or category.budget_id != budget_id or category.is_archived
        or not can_access_resource(db, user, budget, "category", category.id)
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


def _resolve_schedule_resources(db, user, budget, body):
    """Validate a schedule's account/destination/category against the current budget and the
    acting user's live scope. Raises 422/404 exactly like schedule creation; used by update and
    realization so that permission revoked after creation is re-checked at every mutation."""
    account = db.get(Account, body.account_id)
    if account is None or account.budget_id != budget.id or account.is_closed or not can_access_resource(db, user, budget, "account", account.id):
        raise HTTPException(status_code=422, detail="Invalid scheduled account")
    destination = None
    if body.destination_account_id is not None:
        destination = db.get(Account, body.destination_account_id)
        if destination is None or destination.budget_id != budget.id or destination.is_closed or not can_access_resource(db, user, budget, "account", destination.id):
            raise HTTPException(status_code=422, detail="Invalid scheduled destination account")
    category = None
    if body.category_id is not None:
        category = db.get(Category, body.category_id)
        if category is None or category.budget_id != budget.id or category.is_archived or not can_access_resource(db, user, budget, "category", category.id):
            raise HTTPException(status_code=422, detail="Invalid scheduled category")
        if not account.is_on_budget:
            raise HTTPException(status_code=422, detail="Tracking accounts cannot affect budget categories")
    return account, destination, category


@router.put("/scheduled-transactions/{schedule_id}", response_model=ScheduledTransactionResponse)
def update_scheduled_transaction(
    budget_id: str,
    schedule_id: str,
    body: ScheduledTransactionUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ScheduledTransaction:
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    schedule = db.scalar(select(ScheduledTransaction).where(
        ScheduledTransaction.id == schedule_id,
        ScheduledTransaction.budget_id == budget_id,
    ).with_for_update())
    if schedule is None or not can_access_resource(db, user, budget, "account", schedule.account_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Scheduled transaction not found")
    # Editing a schedule is planning metadata only; it never touches actuals. Last-writer-wins.
    _resolve_schedule_resources(db, user, budget, body)
    for field, value in body.model_dump().items():
        setattr(schedule, field, value)
    db.commit()
    db.refresh(schedule)
    return schedule


@router.delete("/scheduled-transactions/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_scheduled_transaction(
    budget_id: str,
    schedule_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = require_budget_capability(db, user, budget_id, "manage_planning")
    schedule = db.scalar(select(ScheduledTransaction).where(
        ScheduledTransaction.id == schedule_id,
        ScheduledTransaction.budget_id == budget_id,
    ))
    if schedule is None or not can_access_resource(db, user, budget, "account", schedule.account_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Scheduled transaction not found")
    # Deleting a schedule removes only the future plan. Actual transactions already realized from it
    # are preserved; their `scheduled_transaction_id` lineage remains for audit.
    db.delete(schedule)
    db.commit()


@router.post("/scheduled-transactions/{schedule_id}/realize", response_model=ScheduledRealizationResponse)
def realize_scheduled_transaction(
    budget_id: str,
    schedule_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ScheduledRealizationResponse:
    # Realization creates a real transaction, so it requires create-transaction authority *now*
    # (not whoever created the schedule) and re-checks resource scope below.
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    schedule = db.scalar(select(ScheduledTransaction).where(
        ScheduledTransaction.id == schedule_id,
        ScheduledTransaction.budget_id == budget_id,
    ).with_for_update())
    if schedule is None or not can_access_resource(db, user, budget, "account", schedule.account_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Scheduled transaction not found")
    if not schedule.is_active:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Scheduled transaction is inactive")
    realized_on = schedule.next_date
    if realized_on > date.today():
        raise HTTPException(status_code=422, detail="Occurrence is not due yet")

    # Re-validate resources against live scope; then reuse the SAME accounting engine as manual
    # entry so scheduled realization can never diverge from normal transaction/credit semantics.
    account, destination, category = _resolve_schedule_resources(db, user, budget, schedule)
    account = db.scalar(select(Account).where(Account.id == schedule.account_id).with_for_update())

    created_ids: list[str] = []
    if destination is not None:
        destination = db.scalar(select(Account).where(Account.id == schedule.destination_account_id).with_for_update())
        if account.account_type == "credit" and destination.account_type == "credit":
            raise HTTPException(status_code=422, detail="Credit-to-credit transfers are not supported")
        transfer_id = str(uuid4())
        common = {
            "budget_id": budget_id, "occurred_on": realized_on, "memo": schedule.memo,
            "payee_name": schedule.name, "is_cleared": False, "created_by_user_id": user.id,
            "transfer_id": transfer_id, "scheduled_transaction_id": schedule.id,
        }
        source_txn = Transaction(account_id=account.id, amount_minor=-schedule.amount_minor, **common)
        destination_txn = Transaction(account_id=destination.id, amount_minor=schedule.amount_minor, **common)
        db.add_all([source_txn, destination_txn])
        db.flush()
        if destination.account_type == "credit":
            add_payment_reserve_event(db, credit_account=destination, transfer_id=transfer_id, occurred_on=realized_on, amount_minor=-schedule.amount_minor, actor=user, kind="payment")
        elif account.account_type == "credit":
            add_payment_reserve_event(db, credit_account=account, transfer_id=transfer_id, occurred_on=realized_on, amount_minor=schedule.amount_minor, actor=user, kind="payment_reversal")
        created_ids = [source_txn.id, destination_txn.id]
    else:
        transaction = Transaction(
            budget_id=budget_id, account_id=account.id, category_id=schedule.category_id,
            amount_minor=schedule.amount_minor, occurred_on=realized_on, payee_name=schedule.name,
            memo=schedule.memo, is_cleared=False, created_by_user_id=user.id,
            scheduled_transaction_id=schedule.id,
        )
        db.add(transaction)
        db.flush()
        if category is not None:
            add_purchase_reserve_events(db, account=account, transaction=transaction, category_amounts=[(category, schedule.amount_minor)], actor=user)
        created_ids = [transaction.id]

    # Advance the schedule atomically under the row lock so the same occurrence cannot post twice.
    following = next_occurrence(realized_on, schedule.recurrence_unit, schedule.interval_count)
    schedule.last_realized_on = realized_on
    if following is None:
        schedule.is_active = False
    else:
        schedule.next_date = following
    db.commit()
    return ScheduledRealizationResponse(
        scheduled_transaction_id=schedule.id,
        transaction_ids=created_ids,
        realized_on=realized_on,
        next_date=None if following is None else schedule.next_date,
        is_active=schedule.is_active,
        last_realized_on=realized_on,
    )


@router.get("/forecast", response_model=ForecastResponse)
def forecast(
    budget_id: str,
    through: date = Query(...),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ForecastResponse:
    budget = require_budget_capability(db, user, budget_id, "view_account_balances")
    today = date.today()
    if through < today or through > today + timedelta(days=366):
        raise HTTPException(status_code=422, detail="Forecast horizon must be between today and one year")
    accounts = list(db.scalars(select(Account).where(
        Account.budget_id == budget_id,
    ).order_by(Account.name)))
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    if visible_accounts is not None:
        accounts = [account for account in accounts if account.id in visible_accounts]
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
    schedules = [schedule for schedule in schedules if (
        schedule.account_id in accounts_by_id
        and (schedule.destination_account_id is None or schedule.destination_account_id in accounts_by_id)
    )]
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
