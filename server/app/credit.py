from __future__ import annotations

from datetime import date

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .allocation import category_available_balance
from .models import (
    Account,
    Category,
    CategoryGroup,
    CreditCardReserveEvent,
    Transaction,
    User,
)


def ensure_credit_payment_category(db: Session, account: Account) -> Category:
    if account.account_type != "credit":
        raise ValueError("payment categories belong only to credit accounts")
    if account.payment_category_id:
        category = db.get(Category, account.payment_category_id)
        if category is not None:
            return category
    group = db.scalar(select(CategoryGroup).where(
        CategoryGroup.budget_id == account.budget_id,
        CategoryGroup.name == "Credit Card Payments",
    ))
    if group is None:
        group = CategoryGroup(
            budget_id=account.budget_id,
            name="Credit Card Payments",
            sort_order=-100,
        )
        db.add(group)
        db.flush()
    category = Category(
        budget_id=account.budget_id,
        group_id=group.id,
        name=f"{account.name} Payment",
        sort_order=0,
        system_type="credit_payment",
        linked_account_id=account.id,
    )
    db.add(category)
    db.flush()
    account.payment_category_id = category.id
    return category


def reserve_event_balance(
    db: Session,
    payment_category_id: str,
    *,
    before: date | None = None,
    through: date | None = None,
    credit_account_id: str | None = None,
    spending_category_id: str | None = None,
) -> int:
    conditions = [CreditCardReserveEvent.payment_category_id == payment_category_id]
    if before is not None:
        conditions.append(CreditCardReserveEvent.occurred_on < before)
    if through is not None:
        conditions.append(CreditCardReserveEvent.occurred_on <= through)
    if credit_account_id is not None:
        conditions.append(CreditCardReserveEvent.credit_account_id == credit_account_id)
    if spending_category_id is not None:
        conditions.append(CreditCardReserveEvent.spending_category_id == spending_category_id)
    return int(db.scalar(select(
        func.coalesce(func.sum(CreditCardReserveEvent.amount_minor), 0)
    ).where(*conditions)) or 0)


def add_purchase_reserve_events(
    db: Session,
    *,
    account: Account,
    transaction: Transaction,
    category_amounts: list[tuple[Category, int]],
    actor: User,
) -> None:
    if account.account_type != "credit" or account.payment_category_id is None:
        return
    existing_payment_money = category_available_balance(
        db, account.budget_id, account.payment_category_id, through=transaction.occurred_on
    )
    refund_remaining_payment_money = max(existing_payment_money, 0)
    for category, amount_minor in category_amounts:
        if category.system_type == "credit_payment":
            raise HTTPException(status_code=422, detail="Card purchases cannot use a payment category")
        if amount_minor < 0:
            available_after_transaction = category_available_balance(
                db, account.budget_id, category.id, through=transaction.occurred_on
            )
            available_before_transaction = available_after_transaction - amount_minor
            funded = min(
                -amount_minor,
                max(available_before_transaction, 0),
            )
            reserve_amount = funded
            kind = "funded_purchase"
        else:
            category_purchase_reserve = max(reserve_event_balance(
                db,
                account.payment_category_id,
                through=transaction.occurred_on,
                credit_account_id=account.id,
                spending_category_id=category.id,
            ), 0)
            reserve_amount = -min(
                amount_minor,
                category_purchase_reserve,
                refund_remaining_payment_money,
            )
            refund_remaining_payment_money += reserve_amount
            kind = "refund_release"
        if reserve_amount == 0:
            continue
        db.add(CreditCardReserveEvent(
            budget_id=account.budget_id,
            credit_account_id=account.id,
            payment_category_id=account.payment_category_id,
            spending_category_id=category.id,
            source_transaction_id=transaction.id,
            occurred_on=transaction.occurred_on,
            amount_minor=reserve_amount,
            kind=kind,
            actor_user_id=actor.id,
        ))


def add_payment_reserve_event(
    db: Session,
    *,
    credit_account: Account,
    transfer_id: str,
    occurred_on: date,
    amount_minor: int,
    actor: User,
    kind: str,
) -> None:
    if credit_account.payment_category_id is None:
        raise ValueError("credit account is missing its payment category")
    if amount_minor < 0:
        available = category_available_balance(
            db,
            credit_account.budget_id,
            credit_account.payment_category_id,
            through=occurred_on,
        )
        if available < -amount_minor:
            raise HTTPException(status_code=409, detail="Credit-card payment is not fully funded")
    db.add(CreditCardReserveEvent(
        budget_id=credit_account.budget_id,
        credit_account_id=credit_account.id,
        payment_category_id=credit_account.payment_category_id,
        spending_category_id=None,
        transfer_id=transfer_id,
        occurred_on=occurred_on,
        amount_minor=amount_minor,
        kind=kind,
        actor_user_id=actor.id,
    ))
