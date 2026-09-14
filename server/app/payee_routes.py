from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from .access import can_access_resource, visible_resource_ids
from .budgeting_routes import require_budget_capability
from .database import get_db
from .dependencies import get_current_user
from .models import Budget, Category, Payee, PayeeAlias, PayeeBudgetPreference, Transaction, TransactionChange, User
from .payee_names import display_payee_name, normalized_payee_name
from .schemas import PayeeAliasCreate, PayeeAliasResponse, PayeeCreate, PayeeMerge, PayeeResponse, PayeeUpdate


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


def _payee(db: Session, budget: Budget, payee_id: str) -> Payee:
    payee = db.scalar(select(Payee).where(Payee.id == payee_id, Payee.household_id == budget.household_id))
    if payee is None:
        raise HTTPException(status_code=404, detail="Payee not found")
    return payee


def _preference(db: Session, budget_id: str, payee_id: str) -> PayeeBudgetPreference | None:
    return db.scalar(select(PayeeBudgetPreference).where(
        PayeeBudgetPreference.budget_id == budget_id, PayeeBudgetPreference.payee_id == payee_id
    ))


def _visible_transactions(db: Session, user: User, budget: Budget) -> list[Transaction]:
    accounts = visible_resource_ids(db, user, budget, "account")
    categories = visible_resource_ids(db, user, budget, "category")
    rows = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(Transaction.budget_id == budget.id)))
    return [row for row in rows if
            (accounts is None or row.account_id in accounts) and
            (categories is None or
             (row.category_id is not None and row.category_id in categories) or
             (not row.splits and row.category_id is None) or
             (bool(row.splits) and all(split.category_id in categories for split in row.splits)))]


def _response(db: Session, budget: Budget, payee: Payee, visible: list[Transaction]) -> dict:
    rows = [row for row in visible if row.payee_id == payee.id]
    preference = _preference(db, budget.id, payee.id)
    return {
        "id": payee.id, "household_id": payee.household_id, "display_name": payee.display_name,
        "is_archived": payee.is_archived, "merged_into_payee_id": payee.merged_into_payee_id,
        "default_category_id": preference.default_category_id if preference else None,
        "transaction_count": len(rows), "net_amount_minor": sum(row.amount_minor for row in rows),
        "aliases": list(db.scalars(select(PayeeAlias).where(PayeeAlias.payee_id == payee.id).order_by(PayeeAlias.display_name))),
    }


@router.get("/payees", response_model=list[PayeeResponse])
def list_payees(budget_id: str, include_archived: bool = False, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> list[dict]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    visible = _visible_transactions(db, user, budget)
    query = select(Payee).where(Payee.household_id == budget.household_id)
    if not include_archived:
        query = query.where(Payee.is_archived.is_(False), Payee.merged_into_payee_id.is_(None))
    payees = list(db.scalars(query.order_by(Payee.display_name, Payee.id)))
    # A scoped member may discover a payee only through a transaction they can already see.
    if visible_resource_ids(db, user, budget, "account") is not None or visible_resource_ids(db, user, budget, "category") is not None:
        visible_ids = {row.payee_id for row in visible if row.payee_id is not None}
        payees = [item for item in payees if item.id in visible_ids]
    return [_response(db, budget, item, visible) for item in payees]


def _set_preference(db: Session, budget: Budget, payee: Payee, category_id: str | None, user: User) -> None:
    preference = _preference(db, budget.id, payee.id)
    if category_id is not None:
        category = db.get(Category, category_id)
        if category is None or category.budget_id != budget.id or category.is_archived or not can_access_resource(db, user, budget, "category", category.id):
            raise HTTPException(status_code=422, detail="Invalid default category")
    if preference is None and category_id is not None:
        db.add(PayeeBudgetPreference(payee_id=payee.id, budget_id=budget.id, default_category_id=category_id, updated_by_user_id=user.id))
    elif preference is not None:
        if category_id is None:
            db.delete(preference)
        else:
            preference.default_category_id = category_id
            preference.updated_by_user_id = user.id


@router.post("/payees", response_model=PayeeResponse, status_code=status.HTTP_201_CREATED)
def create_payee(budget_id: str, body: PayeeCreate, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    budget = require_budget_capability(db, user, budget_id, "create_transaction")
    name = display_payee_name(body.display_name)
    if not name:
        raise HTTPException(status_code=422, detail="Enter a payee name")
    payee = Payee(household_id=budget.household_id, display_name=name, name_key=normalized_payee_name(name), created_by_user_id=user.id)
    db.add(payee)
    try:
        db.flush()
        _set_preference(db, budget, payee, body.default_category_id, user)
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A payee with this name already exists")
    visible = _visible_transactions(db, user, budget)
    return _response(db, budget, payee, visible)


@router.put("/payees/{payee_id}", response_model=PayeeResponse)
def update_payee(budget_id: str, payee_id: str, body: PayeeUpdate, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    budget = require_budget_capability(db, user, budget_id, "manage_payees")
    payee = _payee(db, budget, payee_id)
    if payee.merged_into_payee_id is not None:
        raise HTTPException(status_code=409, detail="Merged payees cannot be edited")
    name = display_payee_name(body.display_name)
    if not name:
        raise HTTPException(status_code=422, detail="Enter a payee name")
    payee.display_name, payee.name_key, payee.is_archived = name, normalized_payee_name(name), body.is_archived
    _set_preference(db, budget, payee, body.default_category_id, user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="A payee with this name already exists")
    return _response(db, budget, payee, _visible_transactions(db, user, budget))


@router.post("/payees/{payee_id}/aliases", response_model=PayeeAliasResponse, status_code=status.HTTP_201_CREATED)
def create_alias(budget_id: str, payee_id: str, body: PayeeAliasCreate, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> PayeeAlias:
    budget = require_budget_capability(db, user, budget_id, "manage_payees")
    payee = _payee(db, budget, payee_id)
    name = display_payee_name(body.display_name)
    if not name:
        raise HTTPException(status_code=422, detail="Enter an alias")
    key = normalized_payee_name(name)
    collision = db.scalar(select(PayeeAlias).join(Payee, Payee.id == PayeeAlias.payee_id).where(Payee.household_id == budget.household_id, PayeeAlias.name_key == key))
    if collision is not None:
        raise HTTPException(status_code=409, detail="This alias is already in use")
    alias = PayeeAlias(payee_id=payee.id, display_name=name, name_key=key, created_by_user_id=user.id)
    db.add(alias); db.commit(); db.refresh(alias)
    return alias


@router.delete("/payees/{payee_id}/aliases/{alias_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_alias(budget_id: str, payee_id: str, alias_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> None:
    budget = require_budget_capability(db, user, budget_id, "manage_payees")
    _payee(db, budget, payee_id)
    alias = db.scalar(select(PayeeAlias).where(PayeeAlias.id == alias_id, PayeeAlias.payee_id == payee_id))
    if alias is None:
        raise HTTPException(status_code=404, detail="Alias not found")
    db.delete(alias); db.commit()


@router.post("/payees/{payee_id}/merge", response_model=PayeeResponse)
def merge_payee(budget_id: str, payee_id: str, body: PayeeMerge, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    budget = require_budget_capability(db, user, budget_id, "manage_payees")
    source, destination = _payee(db, budget, payee_id), _payee(db, budget, body.destination_payee_id)
    if source.id == destination.id or source.merged_into_payee_id is not None or destination.merged_into_payee_id is not None:
        raise HTTPException(status_code=409, detail="Choose two active payees")
    for transaction in db.scalars(select(Transaction).where(Transaction.payee_id == source.id)):
        before = transaction.payee_id
        transaction.payee_id = destination.id
        transaction.payee_name = destination.display_name
        db.add(TransactionChange(budget_id=transaction.budget_id, transaction_id=transaction.id, actor_user_id=user.id,
                                 action="payee_merged", before_json=f'{{"payee_id":"{before}"}}', after_json=f'{{"payee_id":"{destination.id}"}}'))
    for alias in db.scalars(select(PayeeAlias).where(PayeeAlias.payee_id == source.id)):
        alias.payee_id = destination.id
    db.execute(delete(PayeeBudgetPreference).where(PayeeBudgetPreference.payee_id == source.id))
    source.merged_into_payee_id = destination.id
    source.is_archived = True
    source.name_key = None
    db.commit()
    return _response(db, budget, destination, _visible_transactions(db, user, budget))
