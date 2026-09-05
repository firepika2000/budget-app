from __future__ import annotations

from collections import defaultdict
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from .access import visible_resource_ids
from .budgeting_routes import require_budget_capability
from .database import get_db
from .dependencies import get_current_user
from .models import Account, Category, CategoryGroup, Transaction, User
from .schemas import IncomeSpendingReportResponse, SpendingReportResponse


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/reports")


def report_transactions(
    db: Session,
    user: User,
    budget_id: str,
    start_date: date,
    end_date: date,
    account_ids: list[str],
    category_ids: list[str],
    category_groups: list[str],
    member_ids: list[str],
    payees: list[str],
    transaction_type: Optional[str],
    cleared: Optional[bool],
    include_tracking: bool,
) -> tuple[object, list[Transaction]]:
    if start_date > end_date:
        raise HTTPException(status_code=422, detail="Report start date must not follow end date")
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    if visible_accounts is not None and any(value not in visible_accounts for value in account_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if visible_categories is not None and any(value not in visible_categories for value in category_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    query = select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id,
        Transaction.occurred_on >= start_date,
        Transaction.occurred_on <= end_date,
    )
    if account_ids:
        query = query.where(Transaction.account_id.in_(account_ids))
    if member_ids:
        query = query.where(Transaction.created_by_user_id.in_(member_ids))
    if cleared is not None:
        query = query.where(Transaction.is_cleared.is_(cleared))
    transactions = list(db.scalars(query.order_by(Transaction.occurred_on.desc(), Transaction.created_at.desc())))
    group_category_ids = set(db.scalars(select(Category.id).join(CategoryGroup, CategoryGroup.id == Category.group_id).where(
        Category.budget_id == budget_id, CategoryGroup.name.in_(category_groups)
    ))) if category_groups else set()
    tracking_ids = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id, Account.is_on_budget.is_(False))))
    normalized_payees = {value.casefold() for value in payees}
    transactions = [item for item in transactions if (
        (visible_accounts is None or item.account_id in visible_accounts)
        and (
            visible_categories is None
            or item.category_id in visible_categories
            or (bool(item.splits) and all(split.category_id in visible_categories for split in item.splits))
        )
        and (
            not category_ids
            or item.category_id in category_ids
            or any(split.category_id in category_ids for split in item.splits)
        )
        and (not category_groups or item.category_id in group_category_ids or any(split.category_id in group_category_ids for split in item.splits))
        and (not normalized_payees or item.payee_name.casefold() in normalized_payees)
        and (include_tracking or item.account_id not in tracking_ids)
        and (
            transaction_type is None
            or (transaction_type == "transfer" and item.transfer_id is not None)
            or (transaction_type == "income" and item.transfer_id is None and item.amount_minor > 0 and item.category_id is None and not item.splits)
            or (transaction_type == "spending" and item.transfer_id is None and item.amount_minor < 0 and (item.category_id is not None or bool(item.splits)))
            or (transaction_type == "refund" and item.transfer_id is None and item.amount_minor > 0 and (item.category_id is not None or bool(item.splits)))
        )
    )]
    return budget, transactions


@router.get("/spending", response_model=SpendingReportResponse)
def spending_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    category_id: list[str] = Query(default=[]),
    category_group: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    transaction_type: Optional[str] = Query(default=None, pattern="^(income|spending|refund|transfer)$"),
    cleared: Optional[bool] = None,
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget, transactions = report_transactions(db, user, budget_id, start_date, end_date, account_id, category_id, category_group, member_id, payee, transaction_type, cleared, include_tracking)
    categories = {
        item.id: item for item in db.scalars(select(Category).where(Category.budget_id == budget_id))
    }
    groups = {
        item.id: item.name for item in db.scalars(select(CategoryGroup).where(CategoryGroup.budget_id == budget_id))
    }
    totals: dict[str, int] = defaultdict(int)
    transaction_ids: dict[str, list[str]] = defaultdict(list)
    for transaction in transactions:
        if transaction.transfer_id is not None or transaction.amount_minor == 0:
            continue
        portions = (
            [(transaction.category_id, transaction.amount_minor)] if transaction.category_id is not None
            else [(split.category_id, split.amount_minor) for split in transaction.splits]
        )
        for category, amount in portions:
            if category is None or amount == 0 or (category_id and category not in category_id):
                continue
            # Negative categorized amounts are spending; positive categorized amounts are
            # refunds/reversals that reduce spending. A positive amount must never become income.
            totals[category] -= amount
            transaction_ids[category].append(transaction.id)
    rows = []
    for category, amount in totals.items():
        if amount <= 0:
            # Net non-spending (fully refunded or net-inflow) categories are omitted from the ranking.
            continue
        model = categories[category]
        rows.append({
            "category_id": category,
            "category_name": model.name,
            "category_group": groups.get(model.group_id, "Uncategorized"),
            "spending_minor": amount,
            "transaction_ids": transaction_ids[category],
        })
    rows.sort(key=lambda item: (-item["spending_minor"], item["category_name"]))
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "total_spending_minor": sum(item["spending_minor"] for item in rows), "categories": rows,
    }


@router.get("/income-spending", response_model=IncomeSpendingReportResponse)
def income_spending_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    cleared: Optional[bool] = None,
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget, transactions = report_transactions(db, user, budget_id, start_date, end_date, account_id, [], [], member_id, payee, None, cleared, include_tracking)
    on_budget_accounts = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id, Account.is_on_budget.is_(True))))
    included = [item for item in transactions if item.transfer_id is None and item.account_id in on_budget_accounts]
    income = [item for item in included if item.amount_minor > 0 and item.category_id is None and not item.splits]
    # Categorized/split transactions participate in spending; positive categorized amounts are
    # refunds that reduce spending rather than income. Uncategorized inflow alone is income.
    spending = [item for item in included if item.category_id is not None or item.splits]
    income_minor = sum(item.amount_minor for item in income)
    spending_minor = 0
    for item in spending:
        portions = (
            [item.amount_minor] if item.category_id is not None
            else [split.amount_minor for split in item.splits]
        )
        spending_minor += sum(-amount for amount in portions)
    difference = income_minor - spending_minor
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "income_minor": income_minor, "spending_minor": spending_minor, "difference_minor": difference,
        "savings_rate": difference / income_minor if income_minor > 0 else None,
        "income_transaction_ids": [item.id for item in income],
        "spending_transaction_ids": [item.id for item in spending],
    }
