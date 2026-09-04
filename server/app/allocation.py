from __future__ import annotations

from dataclasses import dataclass
from datetime import date

from fastapi import HTTPException, status
from sqlalchemy import exists, func, select
from sqlalchemy.orm import Session

from .models import (
    Account,
    AllocationOperation,
    AllocationPosting,
    Budget,
    Category,
    Transaction,
    TransactionSplit,
    User,
)


MIN_LEDGER_AMOUNT = -(2**63) + 1
MAX_LEDGER_AMOUNT = 2**63 - 1


@dataclass(frozen=True)
class PostingInput:
    bucket: str
    amount_minor: int
    category_id: str | None = None


def lock_budget(db: Session, budget_id: str) -> Budget:
    budget = db.scalar(select(Budget).where(Budget.id == budget_id).with_for_update())
    if budget is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    return budget


def require_version(budget: Budget, expected_version: int | None) -> None:
    if expected_version is not None and budget.allocation_version != expected_version:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": "The allocation plan changed. Refresh and try again.",
                "current_allocation_version": budget.allocation_version,
            },
        )


def append_operation(
    db: Session,
    *,
    budget: Budget,
    actor: User,
    occurred_on: date,
    kind: str,
    postings: list[PostingInput],
    note: str = "",
    source: str = "manual",
    reversal_of_id: str | None = None,
) -> AllocationOperation:
    if len(postings) < 2 or sum(item.amount_minor for item in postings) != 0:
        raise ValueError("allocation postings must contain at least two entries and balance to zero")
    category_ids = {item.category_id for item in postings if item.category_id is not None}
    categories = {
        item.id: item for item in db.scalars(select(Category).where(Category.id.in_(category_ids)))
    } if category_ids else {}
    for posting in postings:
        if not MIN_LEDGER_AMOUNT <= posting.amount_minor <= MAX_LEDGER_AMOUNT or posting.amount_minor == 0:
            raise ValueError("allocation posting is outside the supported nonzero minor-unit range")
        if posting.bucket == "category":
            category = categories.get(posting.category_id)
            if category is None or category.budget_id != budget.id or category.is_archived:
                raise HTTPException(status_code=422, detail="Invalid allocation category")
        elif posting.bucket != "ready_to_assign" or posting.category_id is not None:
            raise ValueError("invalid allocation bucket")
    operation = AllocationOperation(
        budget_id=budget.id,
        occurred_on=occurred_on,
        kind=kind,
        actor_user_id=actor.id,
        note=note.strip(),
        source=source,
        reversal_of_id=reversal_of_id,
    )
    operation.postings = [AllocationPosting(
        budget_id=budget.id,
        bucket=item.bucket,
        category_id=item.category_id,
        amount_minor=item.amount_minor,
    ) for item in postings]
    db.add(operation)
    budget.allocation_version += 1
    return operation


def allocation_balance(
    db: Session,
    budget_id: str,
    *,
    category_id: str | None,
    before: date | None = None,
    through: date | None = None,
) -> int:
    conditions = [
        AllocationPosting.budget_id == budget_id,
        AllocationPosting.category_id == category_id,
    ]
    if before is not None:
        conditions.append(AllocationOperation.occurred_on < before)
    if through is not None:
        conditions.append(AllocationOperation.occurred_on <= through)
    value = db.scalar(
        select(func.coalesce(func.sum(AllocationPosting.amount_minor), 0))
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(*conditions)
    )
    return int(value or 0)


def unassigned_cash_balance(db: Session, budget_id: str, through: date | None = None) -> int:
    conditions = [
        Transaction.budget_id == budget_id,
        Transaction.category_id.is_(None),
        Transaction.transfer_id.is_(None),
        Account.is_on_budget.is_(True),
        ~exists().where(TransactionSplit.transaction_id == Transaction.id),
    ]
    if through is not None:
        conditions.append(Transaction.occurred_on <= through)
    value = db.scalar(
        select(func.coalesce(func.sum(Transaction.amount_minor), 0))
        .join(Account, Account.id == Transaction.account_id)
        .where(*conditions)
    )
    return int(value or 0)


def ready_to_assign_balance(db: Session, budget_id: str, through: date | None = None) -> int:
    return unassigned_cash_balance(db, budget_id, through) + allocation_balance(
        db, budget_id, category_id=None, through=through
    )


def category_activity_balance(
    db: Session,
    budget_id: str,
    category_id: str,
    *,
    before: date | None = None,
    through: date | None = None,
) -> int:
    direct_conditions = [
        Transaction.budget_id == budget_id,
        Transaction.category_id == category_id,
        Account.is_on_budget.is_(True),
    ]
    split_conditions = [
        Transaction.budget_id == budget_id,
        TransactionSplit.category_id == category_id,
        Account.is_on_budget.is_(True),
    ]
    if before is not None:
        direct_conditions.append(Transaction.occurred_on < before)
        split_conditions.append(Transaction.occurred_on < before)
    if through is not None:
        direct_conditions.append(Transaction.occurred_on <= through)
        split_conditions.append(Transaction.occurred_on <= through)
    direct = db.scalar(
        select(func.coalesce(func.sum(Transaction.amount_minor), 0))
        .join(Account, Account.id == Transaction.account_id)
        .where(*direct_conditions)
    )
    splits = db.scalar(
        select(func.coalesce(func.sum(TransactionSplit.amount_minor), 0))
        .join(Transaction, Transaction.id == TransactionSplit.transaction_id)
        .join(Account, Account.id == Transaction.account_id)
        .where(*split_conditions)
    )
    return int(direct or 0) + int(splits or 0)


def category_available_balance(
    db: Session,
    budget_id: str,
    category_id: str,
    through: date | None = None,
) -> int:
    return allocation_balance(db, budget_id, category_id=category_id, through=through) + category_activity_balance(
        db, budget_id, category_id, through=through
    )
