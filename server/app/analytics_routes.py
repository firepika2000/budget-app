from __future__ import annotations

from collections import defaultdict
import csv
from datetime import date, timedelta
import io
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload
from starlette.responses import Response

from .access import has_capability, is_household_owner, visible_resource_ids
from .budgeting_routes import account_working_balances, require_budget_capability
from .calendar_dates import month_periods
from .cash_rollover_repository import cash_rollover_effects
from .debt_projection import estimated_monthly_interest
from .database import get_db
from .dependencies import get_current_user
from .models import Account, AccountDebtTerms, AllocationOperation, AllocationPosting, Category, CategoryGroup, CreditCardReserveEvent, Membership, Transaction, TransactionSplit, User
from .planning_routes import forecast
from .schemas import DebtCostResponse, DebtReportResponse, IncomeSpendingReportResponse, InsightsSummaryResponse, NetWorthReportResponse, PlanPerformanceReportResponse, ResilienceReportResponse, SpendingReportResponse, SpendingTrendsReportResponse


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/reports")
MAX_REPORT_TRANSACTION_IDS = 500
MAX_REPORT_MONTHS = 600


@router.get("/debt-cost", response_model=DebtCostResponse)
def debt_cost_report(
    budget_id: str,
    account_id: list[str] = Query(default=[]),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Estimate current simple monthly cost, distinct from recorded/historical interest."""
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    visible = visible_resource_ids(db, user, budget, "account")
    budget_accounts = dict(db.execute(select(Account.id, Account.account_type).where(Account.budget_id == budget_id)).all())
    eligible_ids = {key for key, kind in budget_accounts.items() if kind in {"credit", "loan"}}
    if any(value not in budget_accounts or (visible is not None and value not in visible) for value in account_id):
        raise HTTPException(status_code=404, detail="Report resource not found")
    selected = set(account_id) & eligible_ids if account_id else eligible_ids
    if visible is not None:
        selected &= visible
    rows = []
    as_of = date.today()
    balances = account_working_balances(db, list(selected))
    accounts = db.execute(select(Account, AccountDebtTerms).outerjoin(
        AccountDebtTerms, AccountDebtTerms.account_id == Account.id
    ).where(Account.id.in_(selected)).order_by(Account.name, Account.id)) if selected else []
    for account, terms in accounts:
        principal = max(-balances[account.id], 0)
        rate = terms.annual_rate_basis_points if terms else None
        if terms and terms.promotional_rate_basis_points is not None and terms.promotional_ends_on is not None and as_of <= terms.promotional_ends_on:
            rate = terms.promotional_rate_basis_points
        try:
            bounded_estimate = estimated_monthly_interest(principal, rate if rate is not None else 0)
            estimate = bounded_estimate if rate is not None else None
        except (ValueError, OverflowError) as error:
            raise HTTPException(status_code=422, detail="Debt cost exceeds the supported money range") from error
        rows.append({"account_id": account.id, "account_name": account.name, "principal_minor": principal,
                     "effective_rate_basis_points": rate, "estimated_monthly_interest_minor": estimate,
                     "missing_fields": ["annual_rate_basis_points"] if rate is None else []})
    return {"as_of": as_of, "currency_code": budget.currency_code, "accounts": rows}


def _bounded_ids(values: list[str]) -> tuple[list[str], bool]:
    unique = list(dict.fromkeys(values))
    return unique[:MAX_REPORT_TRANSACTION_IDS], len(unique) > MAX_REPORT_TRANSACTION_IDS


def _validate_report_range(start_date: date, end_date: date) -> None:
    if start_date > end_date:
        raise HTTPException(status_code=422, detail="Report start date must not follow end date")
    month_count = (end_date.year - start_date.year) * 12 + end_date.month - start_date.month + 1
    if month_count > MAX_REPORT_MONTHS:
        raise HTTPException(status_code=422, detail=f"Report range cannot exceed {MAX_REPORT_MONTHS} calendar months")


def _csv_text(value: object) -> object:
    """Prevent spreadsheet formula execution while retaining human-readable open-format text."""
    if isinstance(value, str) and value.startswith(("=", "+", "-", "@")):
        return f"'{value}"
    return value


def _income_spending_values(transactions: list[Transaction]) -> tuple[int, int, list[str], list[str]]:
    income = [item for item in transactions if item.amount_minor > 0 and item.category_id is None and not item.splits]
    categorized = [item for item in transactions if item.category_id is not None or item.splits]
    income_minor = sum(item.amount_minor for item in income)
    spending_minor = sum(
        -amount
        for item in categorized
        for amount in ([item.amount_minor] if item.category_id is not None else [split.amount_minor for split in item.splits])
    )
    return income_minor, spending_minor, [item.id for item in income], [item.id for item in categorized]


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
    reconciled: Optional[bool],
    flags: list[str],
    tags: list[str],
    include_tracking: bool,
) -> tuple[object, list[Transaction]]:
    _validate_report_range(start_date, end_date)
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    budget_account_ids = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id)))
    budget_category_ids = set(db.scalars(select(Category.id).where(Category.budget_id == budget_id)))
    if any(value not in budget_account_ids for value in account_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if any(value not in budget_category_ids for value in category_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if visible_accounts is not None and any(value not in visible_accounts for value in account_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if visible_categories is not None and any(value not in visible_categories for value in category_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    household_member_ids = set(db.scalars(select(Membership.user_id).where(
        Membership.household_id == budget.household_id, Membership.is_active.is_(True)
    )))
    if any(value not in household_member_ids for value in member_ids):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if member_ids and not is_household_owner(db, user, budget.household_id) and not has_capability(db, user, budget, "manage_allowances"):
        if any(value != user.id for value in member_ids):
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
    if reconciled is not None:
        query = query.where(Transaction.is_reconciled.is_(reconciled))
    transactions = list(db.scalars(query.order_by(
        Transaction.occurred_on.desc(), Transaction.created_at.desc(), Transaction.id.desc()
    )))
    group_category_ids = set(db.scalars(select(Category.id).join(CategoryGroup, CategoryGroup.id == Category.group_id).where(
        Category.budget_id == budget_id, CategoryGroup.name.in_(category_groups)
    ))) if category_groups else set()
    if category_groups:
        visible_group_names = set(db.scalars(select(CategoryGroup.name).join(Category, Category.group_id == CategoryGroup.id).where(
            Category.budget_id == budget_id,
            *([] if visible_categories is None else [Category.id.in_(visible_categories)]),
        )))
        if any(value not in visible_group_names for value in category_groups):
            raise HTTPException(status_code=404, detail="Report resource not found")
    tracking_ids = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id, Account.is_on_budget.is_(False))))
    normalized_payees = {value.casefold() for value in payees}
    normalized_flags = {value.strip().casefold() for value in flags if value.strip()}
    normalized_tags = {value.strip().casefold() for value in tags if value.strip()}
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
        and (not normalized_flags or (item.flag or "").casefold() in normalized_flags)
        and (not normalized_tags or normalized_tags.intersection(item.tags or []))
        and (include_tracking or item.account_id not in tracking_ids)
        and (
            transaction_type is None
            or (transaction_type == "transfer" and item.transfer_id is not None)
            or (transaction_type == "income" and item.transfer_id is None and item.amount_minor > 0 and item.category_id is None and not item.splits)
            or (transaction_type == "spending" and item.transfer_id is None and item.amount_minor < 0 and (item.category_id is not None or bool(item.splits)))
            or (transaction_type == "refund" and item.transfer_id is None and item.amount_minor > 0 and (item.category_id is not None or bool(item.splits)))
            or (transaction_type == "interest_charge" and item.transfer_id is None and (
                item.financial_classification == "interest_charge"
                or any(split.financial_classification == "interest_charge" for split in item.splits)
            ))
        )
    )]
    return budget, transactions


@router.get("/spending", response_model=SpendingReportResponse, response_model_exclude_defaults=True)
def spending_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    category_id: list[str] = Query(default=[]),
    category_group: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    transaction_type: Optional[str] = Query(default=None, pattern="^(income|spending|refund|transfer|interest_charge)$"),
    cleared: Optional[bool] = None,
    reconciled: Optional[bool] = None,
    flag: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget, transactions = report_transactions(db, user, budget_id, start_date, end_date, account_id, category_id, category_group, member_id, payee, transaction_type, cleared, reconciled, flag, tag, include_tracking)
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
        bounded_ids, truncated = _bounded_ids(transaction_ids[category])
        rows.append({
            "category_id": category,
            "category_name": model.name,
            "category_group": groups.get(model.group_id, "Uncategorized"),
            "spending_minor": amount,
            "transaction_ids": bounded_ids,
            "transaction_ids_truncated": truncated,
        })
    rows.sort(key=lambda item: (-item["spending_minor"], item["category_name"]))
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "total_spending_minor": sum(item["spending_minor"] for item in rows), "categories": rows,
    }


@router.get("/income-spending", response_model=IncomeSpendingReportResponse, response_model_exclude_defaults=True)
def income_spending_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    cleared: Optional[bool] = None,
    reconciled: Optional[bool] = None,
    flag: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget, transactions = report_transactions(db, user, budget_id, start_date, end_date, account_id, [], [], member_id, payee, None, cleared, reconciled, flag, tag, include_tracking)
    on_budget_accounts = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id, Account.is_on_budget.is_(True))))
    included = [item for item in transactions if item.transfer_id is None and item.account_id in on_budget_accounts]
    # Categorized/split transactions participate in spending; positive categorized amounts are
    # refunds that reduce spending rather than income. Uncategorized inflow alone is income.
    income_minor, spending_minor, income_ids, spending_ids = _income_spending_values(included)
    difference = income_minor - spending_minor
    periods = []
    for period_start, period_end in month_periods(start_date, end_date):
        period_transactions = [item for item in included if period_start <= item.occurred_on <= period_end]
        period_income, period_spending, period_income_ids, period_spending_ids = _income_spending_values(period_transactions)
        bounded_income_ids, income_truncated = _bounded_ids(period_income_ids)
        bounded_spending_ids, spending_truncated = _bounded_ids(period_spending_ids)
        periods.append({
            "period_start": period_start, "period_end": period_end,
            "income_minor": period_income, "spending_minor": period_spending,
            "difference_minor": period_income - period_spending,
            "income_transaction_ids": bounded_income_ids,
            "spending_transaction_ids": bounded_spending_ids,
            "income_transaction_ids_truncated": income_truncated,
            "spending_transaction_ids_truncated": spending_truncated,
        })
    bounded_income_ids, income_truncated = _bounded_ids(income_ids)
    bounded_spending_ids, spending_truncated = _bounded_ids(spending_ids)
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "income_minor": income_minor, "spending_minor": spending_minor, "difference_minor": difference,
        "savings_rate": difference / income_minor if income_minor > 0 else None,
        "income_transaction_ids": bounded_income_ids,
        "spending_transaction_ids": bounded_spending_ids,
        "income_transaction_ids_truncated": income_truncated,
        "spending_transaction_ids_truncated": spending_truncated,
        "periods": periods,
    }


@router.get("/spending-trends", response_model=SpendingTrendsReportResponse, response_model_exclude_defaults=True)
def spending_trends_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    dimension: str = Query(default="category", pattern="^(category|group|payee)$"),
    limit: int = Query(default=12, ge=1, le=25),
    account_id: list[str] = Query(default=[]),
    category_id: list[str] = Query(default=[]),
    category_group: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    transaction_type: Optional[str] = Query(default=None, pattern="^(income|spending|refund|transfer|interest_charge)$"),
    cleared: Optional[bool] = None,
    reconciled: Optional[bool] = None,
    flag: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Return ranked monthly spending series from the canonical authorized report dataset."""
    budget, transactions = report_transactions(
        db, user, budget_id, start_date, end_date, account_id, category_id, category_group,
        member_id, payee, transaction_type, cleared, reconciled, flag, tag, include_tracking,
    )
    categories = {item.id: item for item in db.scalars(select(Category).where(Category.budget_id == budget_id))}
    groups = {item.id: item.name for item in db.scalars(select(CategoryGroup).where(CategoryGroup.budget_id == budget_id))}
    periods = list(month_periods(start_date, end_date))

    totals: dict[str, int] = defaultdict(int)
    names: dict[str, tuple[str, Optional[str]]] = {}
    point_totals: dict[tuple[str, date], int] = defaultdict(int)
    series_ids: dict[str, list[str]] = defaultdict(list)
    point_ids: dict[tuple[str, date], list[str]] = defaultdict(list)
    for transaction in transactions:
        if transaction.transfer_id is not None or transaction.amount_minor == 0:
            continue
        portions = (
            [(transaction.category_id, transaction.amount_minor)] if transaction.category_id is not None
            else [(split.category_id, split.amount_minor) for split in transaction.splits]
        )
        for category_key, amount in portions:
            category = categories.get(category_key)
            if category is None or amount == 0:
                continue
            if dimension == "category":
                key, name, group = category.id, category.name, groups.get(category.group_id, "Uncategorized")
            elif dimension == "group":
                name = groups.get(category.group_id, "Uncategorized")
                key, group = f"group:{name}", None
            else:
                name = transaction.payee_name.strip() or "No payee"
                key, group = f"payee:{name.casefold()}", None
            spending = -amount
            names[key] = (name, group)
            totals[key] += spending
            series_ids[key].append(transaction.id)
            period_start = next(value[0] for value in periods if value[0] <= transaction.occurred_on <= value[1])
            point_totals[(key, period_start)] += spending
            point_ids[(key, period_start)].append(transaction.id)

    ranked = [key for key, value in totals.items() if value > 0]
    ranked.sort(key=lambda key: (-totals[key], names[key][0].casefold(), key))
    rows = []
    for key in ranked[:limit]:
        name, group = names[key]
        bounded_series_ids, series_truncated = _bounded_ids(series_ids[key])
        trend_points = []
        for period_start, period_end in periods:
            bounded_point_ids, point_truncated = _bounded_ids(point_ids[(key, period_start)])
            trend_points.append({
                "period_start": period_start, "period_end": period_end,
                "spending_minor": point_totals[(key, period_start)],
                "transaction_ids": bounded_point_ids,
                "transaction_ids_truncated": point_truncated,
            })
        rows.append({
            "dimension_id": key, "dimension_name": name, "category_group": group,
            "spending_minor": totals[key], "transaction_ids": bounded_series_ids,
            "transaction_ids_truncated": series_truncated,
            "points": trend_points,
        })
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "dimension": dimension, "total_spending_minor": sum(totals[key] for key in ranked),
        "series": rows,
    }


@router.get("/net-worth", response_model=NetWorthReportResponse, response_model_exclude_defaults=True)
def net_worth_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    include_tracking: bool = True,
    include_transaction_ids: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    _validate_report_range(start_date, end_date)
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    budget_account_ids = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id)))
    if any(value not in budget_account_ids for value in account_id):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if visible_accounts is not None and any(value not in visible_accounts for value in account_id):
        raise HTTPException(status_code=404, detail="Report resource not found")
    accounts_query = select(Account).where(Account.budget_id == budget_id)
    if account_id:
        accounts_query = accounts_query.where(Account.id.in_(account_id))
    if visible_accounts is not None:
        accounts_query = accounts_query.where(Account.id.in_(visible_accounts))
    if not include_tracking:
        accounts_query = accounts_query.where(Account.is_on_budget.is_(True))
    accounts = list(db.scalars(accounts_query.order_by(Account.name, Account.id)))
    account_ids = [item.id for item in accounts]
    transactions = list(db.scalars(
        select(Transaction).where(
            Transaction.account_id.in_(account_ids),
            Transaction.occurred_on <= end_date,
        ).order_by(Transaction.occurred_on, Transaction.created_at, Transaction.id)
    )) if account_ids else []

    # Walk the ordered ledger once. The previous implementation rescanned the complete history for
    # every monthly point (O(months × transactions)), which becomes pathological for long-lived
    # budgets. Snapshots retain identical exact/cumulative semantics while aggregation is O(months +
    # transactions); response serialization remains intentionally explicit for drill-through.
    points = []
    observation_dates = [through for _, through in month_periods(start_date, end_date)]
    balances = {value: 0 for value in account_ids}
    contributing_ids: list[str] = []
    transaction_index = 0
    for as_of in observation_dates:
        while transaction_index < len(transactions) and transactions[transaction_index].occurred_on <= as_of:
            transaction = transactions[transaction_index]
            balances[transaction.account_id] += transaction.amount_minor
            contributing_ids.append(transaction.id)
            transaction_index += 1
        assets = sum(max(value, 0) for value in balances.values())
        liabilities = sum(min(value, 0) for value in balances.values())
        total = assets + liabilities
        points.append({
            "as_of": as_of, "assets_minor": assets, "liabilities_minor": liabilities,
            "net_worth_minor": total,
            "transaction_ids": _bounded_ids(contributing_ids)[0] if include_transaction_ids else [],
            "transaction_ids_truncated": _bounded_ids(contributing_ids)[1] if include_transaction_ids else False,
        })
    assets = sum(max(value, 0) for value in balances.values())
    liabilities = sum(min(value, 0) for value in balances.values())
    total = assets + liabilities
    account_rows = []
    for account in accounts:
        account_transactions = [item for item in transactions if item.account_id == account.id]
        account_rows.append({
            "account_id": account.id, "account_name": account.name, "account_type": account.account_type,
            "is_on_budget": account.is_on_budget,
            "balance_minor": sum(item.amount_minor for item in account_transactions),
            "transaction_ids": _bounded_ids([item.id for item in account_transactions])[0] if include_transaction_ids else [],
            "transaction_ids_truncated": _bounded_ids([item.id for item in account_transactions])[1] if include_transaction_ids else False,
        })
    return {
        "start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code,
        "assets_minor": assets, "liabilities_minor": liabilities, "net_worth_minor": total,
        "points": points, "accounts": account_rows,
    }


@router.get("/debt", response_model=DebtReportResponse)
def debt_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Return exact debt observations without inventing interest or payoff assumptions."""
    _validate_report_range(start_date, end_date)
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    budget_accounts = set(db.scalars(select(Account.id).where(Account.budget_id == budget_id)))
    if any(value not in budget_accounts for value in account_id):
        raise HTTPException(status_code=404, detail="Report resource not found")
    if visible_accounts is not None and any(value not in visible_accounts for value in account_id):
        raise HTTPException(status_code=404, detail="Report resource not found")

    query = select(Account).where(
        Account.budget_id == budget_id,
        Account.account_type.in_(("credit", "loan")),
    )
    if account_id:
        query = query.where(Account.id.in_(account_id))
    if visible_accounts is not None:
        query = query.where(Account.id.in_(visible_accounts))
    accounts = list(db.scalars(query.order_by(Account.name, Account.id)))
    account_ids = [account.id for account in accounts]
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.account_id.in_(account_ids), Transaction.occurred_on <= end_date,
    ).order_by(Transaction.occurred_on, Transaction.created_at, Transaction.id))) if account_ids else []

    balances = {value: 0 for value in account_ids}
    index = 0
    while index < len(transactions) and transactions[index].occurred_on < start_date:
        transaction = transactions[index]
        balances[transaction.account_id] += transaction.amount_minor
        index += 1
    opening_debt = sum(max(-value, 0) for value in balances.values())

    observation_dates = [through for _, through in month_periods(start_date, end_date)]
    points = []
    for as_of in observation_dates:
        while index < len(transactions) and transactions[index].occurred_on <= as_of:
            transaction = transactions[index]
            balances[transaction.account_id] += transaction.amount_minor
            index += 1
        points.append({"as_of": as_of, "debt_minor": sum(max(-value, 0) for value in balances.values())})

    ending_debt = sum(max(-value, 0) for value in balances.values())
    def recorded_interest(item: Transaction) -> int:
        if item.transfer_id is not None:
            return 0
        if item.splits:
            return sum(-split.amount_minor for split in item.splits if split.financial_classification == "interest_charge")
        return -item.amount_minor if item.financial_classification == "interest_charge" else 0

    # Balance visibility does not grant access to the classification/history of
    # category-restricted transactions. Apply the same whole-transaction rule
    # as the browser before interest totals, account contributions or dates.
    visible_categories = visible_resource_ids(db, user, budget, "category")
    classified = [item for item in transactions if (
        visible_categories is None
        or item.category_id in visible_categories
        or (bool(item.splits) and all(split.category_id in visible_categories for split in item.splits))
    ) and recorded_interest(item) != 0]
    range_interest = sum(recorded_interest(item) for item in classified if item.occurred_on >= start_date)
    month_start = date(end_date.year, end_date.month, 1)
    year_start = date(end_date.year, 1, 1)
    trailing_start = end_date - timedelta(days=min(364, (end_date - date.min).days))
    account_interest = {
        account_id_value: sum(
            recorded_interest(item) for item in classified
            if item.account_id == account_id_value and item.occurred_on >= start_date
        ) for account_id_value in account_ids
    }
    rows = [{
        "account_id": account.id,
        "account_name": account.name,
        "account_type": account.account_type,
        "is_on_budget": account.is_on_budget,
        "debt_minor": max(-balances[account.id], 0),
        "recorded_interest_minor": account_interest[account.id],
    } for account in accounts]
    rows.sort(key=lambda item: (-item["debt_minor"], item["account_name"], item["account_id"]))
    return {
        "start_date": start_date,
        "end_date": end_date,
        "currency_code": budget.currency_code,
        "opening_debt_minor": opening_debt,
        "debt_minor": ending_debt,
        "principal_reduction_minor": opening_debt - ending_debt,
        "recorded_interest_range_minor": range_interest,
        "recorded_interest_month_minor": sum(recorded_interest(item) for item in classified if item.occurred_on >= month_start),
        "recorded_interest_ytd_minor": sum(recorded_interest(item) for item in classified if item.occurred_on >= year_start),
        "recorded_interest_trailing_12_minor": sum(recorded_interest(item) for item in classified if item.occurred_on >= trailing_start),
        "recorded_interest_lifetime_minor": sum(recorded_interest(item) for item in classified),
        "interest_tracking_started_on": min((item.occurred_on for item in classified), default=None),
        "points": points,
        "accounts": rows,
    }


@router.get("/plan-performance", response_model=PlanPerformanceReportResponse)
def plan_performance_report(
    budget_id: str,
    start_date: date,
    end_date: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Return historical planning observations from allocation, activity, and reserve ledgers."""
    _validate_report_range(start_date, end_date)
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    visible_categories = visible_resource_ids(db, user, budget, "category")
    category_query = select(Category.id).where(Category.budget_id == budget_id)
    if visible_categories is not None:
        category_query = category_query.where(Category.id.in_(visible_categories))
    category_ids = set(db.scalars(category_query))
    account_query = select(Account).where(Account.budget_id == budget_id)
    if visible_accounts is not None:
        account_query = account_query.where(Account.id.in_(visible_accounts))
    accounts = list(db.scalars(account_query))
    account_ids = {item.id for item in accounts}
    cash_account_ids = {item.id for item in accounts if item.is_on_budget and item.account_type in ("checking", "savings", "cash")}

    allocation_rows = db.execute(
        select(AllocationPosting, AllocationOperation)
        .join(AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id)
        .where(AllocationPosting.budget_id == budget_id, AllocationOperation.occurred_on <= end_date)
        .order_by(AllocationOperation.occurred_on, AllocationPosting.id)
    ).all()
    transactions = list(db.scalars(select(Transaction).options(selectinload(Transaction.splits)).where(
        Transaction.budget_id == budget_id,
        Transaction.account_id.in_(account_ids),
        Transaction.occurred_on <= end_date,
    ).order_by(Transaction.occurred_on, Transaction.created_at, Transaction.id))) if account_ids else []
    reserve_events = list(db.scalars(select(CreditCardReserveEvent).where(
        CreditCardReserveEvent.budget_id == budget_id,
        CreditCardReserveEvent.payment_category_id.in_(category_ids),
        CreditCardReserveEvent.credit_account_id.in_(account_ids),
        CreditCardReserveEvent.occurred_on <= end_date,
    ).order_by(CreditCardReserveEvent.occurred_on, CreditCardReserveEvent.id))) if category_ids else []

    category_balances = {value: 0 for value in category_ids}
    ready_postings = 0
    unassigned_cash = 0

    def apply_allocation(posting: AllocationPosting) -> None:
        nonlocal ready_postings
        if posting.bucket == "ready_to_assign":
            if visible_categories is None:
                ready_postings += posting.amount_minor
        elif posting.category_id in category_balances:
            category_balances[posting.category_id] += posting.amount_minor

    def apply_transaction(transaction: Transaction) -> int:
        nonlocal unassigned_cash
        if transaction.account_id in cash_account_ids and transaction.transfer_id is None and transaction.category_id is None and not transaction.splits:
            unassigned_cash += transaction.amount_minor
        activity = 0
        if transaction.category_id in category_balances:
            category_balances[transaction.category_id] += transaction.amount_minor
            activity += transaction.amount_minor
        for split in transaction.splits:
            if split.category_id in category_balances:
                category_balances[split.category_id] += split.amount_minor
                activity += split.amount_minor
        return activity

    def apply_reserve(event: CreditCardReserveEvent) -> int:
        if event.payment_category_id in category_balances:
            category_balances[event.payment_category_id] += event.amount_minor
            return event.amount_minor
        return 0

    allocation_index = transaction_index = reserve_index = 0
    while allocation_index < len(allocation_rows) and allocation_rows[allocation_index][1].occurred_on < start_date:
        apply_allocation(allocation_rows[allocation_index][0]); allocation_index += 1
    while transaction_index < len(transactions) and transactions[transaction_index].occurred_on < start_date:
        apply_transaction(transactions[transaction_index]); transaction_index += 1
    while reserve_index < len(reserve_events) and reserve_events[reserve_index].occurred_on < start_date:
        apply_reserve(reserve_events[reserve_index]); reserve_index += 1

    rollover = cash_rollover_effects(db, budget_id, end_date, category_ids=category_ids, account_ids=account_ids)
    rollover_index = 0
    points = []
    for period_start, period_end in month_periods(start_date, end_date):
        while rollover_index < len(rollover) and rollover[rollover_index].month <= period_start:
            effect = rollover[rollover_index]
            category_balances[effect.category_id] += effect.amount_minor
            if visible_categories is None:
                ready_postings -= effect.amount_minor
            rollover_index += 1
        carried = sum(category_balances.values())
        assigned = activity = transaction_activity = 0
        while allocation_index < len(allocation_rows) and allocation_rows[allocation_index][1].occurred_on <= period_end:
            posting, _operation = allocation_rows[allocation_index]
            if posting.category_id in category_balances:
                assigned += posting.amount_minor
            apply_allocation(posting); allocation_index += 1
        while transaction_index < len(transactions) and transactions[transaction_index].occurred_on <= period_end:
            value = apply_transaction(transactions[transaction_index])
            activity += value; transaction_activity += value; transaction_index += 1
        while reserve_index < len(reserve_events) and reserve_events[reserve_index].occurred_on <= period_end:
            activity += apply_reserve(reserve_events[reserve_index]); reserve_index += 1
        available = sum(category_balances.values())
        points.append({
            "period_start": period_start, "period_end": period_end,
            "assigned_minor": assigned, "activity_minor": activity,
            "spending_minor": -transaction_activity,
            "carried_available_minor": carried, "available_minor": available,
            "overspent_minor": sum(max(-value, 0) for value in category_balances.values()),
            "ready_to_assign_minor": 0 if visible_categories is not None else unassigned_cash + ready_postings,
        })
    return {"start_date": start_date, "end_date": end_date, "currency_code": budget.currency_code, "points": points}


@router.get("/resilience", response_model=ResilienceReportResponse)
def resilience_report(
    budget_id: str,
    horizon_days: int = Query(default=30, ge=1, le=90),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Expose transparent balance/schedule metrics without inventing essential or emergency labels."""
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    require_budget_capability(db, user, budget_id, "view_account_balances")
    today = date.today()
    projection = forecast(budget_id=budget_id, through=today + timedelta(days=horizon_days), user=user, db=db)
    visible_accounts = visible_resource_ids(db, user, budget, "account")
    account_query = select(Account.id).where(
        Account.budget_id == budget_id,
        Account.is_on_budget.is_(True),
        Account.account_type.in_(("checking", "savings", "cash")),
    )
    if visible_accounts is not None:
        account_query = account_query.where(Account.id.in_(visible_accounts))
    cash_ids = set(db.scalars(account_query))
    actual_by_id = {item.account_id: item.actual_balance_minor for item in projection.accounts}
    cash_buffer = sum(actual_by_id.get(account_id, 0) for account_id in cash_ids)
    scheduled_income = sum(item.amount_minor for item in projection.occurrences if item.destination_account_id is None and item.amount_minor > 0)
    scheduled_outflows = sum(-item.amount_minor for item in projection.occurrences if item.destination_account_id is None and item.amount_minor < 0)
    return {
        "as_of": today, "through": projection.through, "currency_code": budget.currency_code,
        "cash_buffer_minor": cash_buffer,
        "current_on_budget_minor": projection.actual_total_on_budget_minor,
        "projected_on_budget_minor": projection.projected_total_on_budget_minor,
        "lowest_projected_on_budget_minor": projection.lowest_projected_total_minor,
        "scheduled_income_minor": scheduled_income, "scheduled_outflows_minor": scheduled_outflows,
        "expected_margin_minor": scheduled_income - scheduled_outflows,
        "essential_expense_coverage_days": None,
        "emergency_fund_coverage_days": None,
        "unavailable_metrics": {
            "essential_expense_coverage_days": "Categories do not yet store authoritative essential-expense classification.",
            "emergency_fund_coverage_days": "Categories do not yet store authoritative emergency-fund classification.",
        },
    }


@router.get("/summary", response_model=InsightsSummaryResponse)
def insights_summary(
    budget_id: str,
    start_date: date,
    end_date: date,
    account_id: list[str] = Query(default=[]),
    member_id: list[str] = Query(default=[]),
    payee: list[str] = Query(default=[]),
    cleared: Optional[bool] = None,
    reconciled: Optional[bool] = None,
    flag: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
    include_tracking: bool = False,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Bounded hub payload using the canonical authorized report definitions.

    This consolidates transport, not a second accounting engine. Internal detailed
    report computation remains a separate performance concern.
    """
    budget = require_budget_capability(db, user, budget_id, "view_reports")
    income = income_spending_report(
        budget_id=budget_id, start_date=start_date, end_date=end_date,
        account_id=account_id, member_id=member_id, payee=payee, cleared=cleared,
        reconciled=reconciled, flag=flag, tag=tag, include_tracking=include_tracking,
        user=user, db=db,
    )
    result = {"currency_code": budget.currency_code, "net_cash_flow_minor": income["difference_minor"]}
    if has_capability(db, user, budget, "view_account_balances"):
        worth = net_worth_report(
            budget_id=budget_id, start_date=start_date, end_date=end_date,
            account_id=account_id, include_tracking=include_tracking,
            include_transaction_ids=False, user=user, db=db,
        )
        debt = debt_report(budget_id=budget_id, start_date=start_date, end_date=end_date, account_id=account_id, user=user, db=db)
        resilience = resilience_report(budget_id=budget_id, horizon_days=30, user=user, db=db)
        result.update(net_worth_minor=worth["net_worth_minor"], debt_minor=debt["debt_minor"],
                      recorded_interest_month_minor=debt["recorded_interest_month_minor"],
                      expected_margin_minor=resilience["expected_margin_minor"])
    return result


@router.get("/export.csv", response_class=Response)
def report_export_csv(
    budget_id: str,
    start_date: date,
    end_date: date,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    """Export bounded report observations as interoperable CSV, distinct from backup JSON."""
    require_budget_capability(db, user, budget_id, "export_data")
    spending = spending_report(
        budget_id, start_date, end_date, account_id=[], category_id=[], category_group=[],
        member_id=[], payee=[], transaction_type=None, cleared=None, reconciled=None, flag=[], tag=[],
        include_tracking=False, user=user, db=db,
    )
    income = income_spending_report(
        budget_id, start_date, end_date, account_id=[], member_id=[], payee=[], cleared=None,
        reconciled=None, flag=[], tag=[], include_tracking=False, user=user, db=db,
    )
    worth = net_worth_report(
        budget_id, start_date, end_date, account_id=[], include_tracking=True,
        include_transaction_ids=False, user=user, db=db,
    )
    debt = debt_report(budget_id, start_date, end_date, account_id=[], user=user, db=db)
    plan = plan_performance_report(budget_id, start_date, end_date, user=user, db=db)
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["report", "period_start", "period_end", "dimension", "name", "amount_minor", "currency_code"])
    currency = spending["currency_code"]
    for row in spending["categories"]:
        writer.writerow(["spending", start_date, end_date, "category", _csv_text(row["category_name"]), row["spending_minor"], currency])
    for row in income["periods"]:
        for name, key in (("income", "income_minor"), ("spending", "spending_minor"), ("net_cash_flow", "difference_minor")):
            writer.writerow(["cash_flow", row["period_start"], row["period_end"], "metric", name, row[key], currency])
    for row in worth["points"]:
        writer.writerow(["net_worth", row["as_of"], row["as_of"], "metric", "net_worth", row["net_worth_minor"], currency])
    for row in debt["points"]:
        writer.writerow(["debt", row["as_of"], row["as_of"], "metric", "debt", row["debt_minor"], currency])
    for row in plan["points"]:
        for name, key in (("assigned", "assigned_minor"), ("spent", "spending_minor"), ("available", "available_minor"), ("unassigned", "ready_to_assign_minor")):
            writer.writerow(["plan", row["period_start"], row["period_end"], "metric", name, row[key], currency])
    filename = f"budget-reports-{start_date.isoformat()}-{end_date.isoformat()}.csv"
    return Response(output.getvalue(), media_type="text/csv; charset=utf-8", headers={
        "Content-Disposition": f'attachment; filename="{filename}"',
    })
