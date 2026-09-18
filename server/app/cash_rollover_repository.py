"""One canonical read adapter for policy-derived balances. No financial writes or read cache."""
from __future__ import annotations

from datetime import date

from sqlalchemy import BigInteger, case, func, literal, select, union_all
from sqlalchemy.orm import Session

from .cash_rollover import CategoryFact, PolicyChange, RolloverEffect, project_rollover_effects
from .models import Account, AllocationOperation, AllocationPosting, CashRolloverPolicyChange, CreditCardReserveEvent, Transaction, TransactionSplit


def cash_rollover_effects(db: Session, budget_id: str, through: date | None = None, *,
                          category_ids: set[str] | None = None, account_ids: set[str] | None = None) -> list[RolloverEffect]:
    """None means all known facts/pending boundaries, never projected schedule income.

    Historical callers receive effects only through their boundary. Global availability callers
    receive a consistent full known-fact projection independent of whichever screen is selected.
    Category-specific guards can narrow inputs because each category's rollover is independent.
    Report callers MUST pass their resource scope before aggregation; this helper does not authorize.
    """
    if category_ids is not None and not category_ids:
        return []
    horizon = (through or date.max).replace(day=1)
    latest = select(func.max(CashRolloverPolicyChange.version)).where(
        CashRolloverPolicyChange.budget_id == budget_id,
        CashRolloverPolicyChange.effective_month <= horizon,
    ).group_by(CashRolloverPolicyChange.effective_month)
    history = [PolicyChange(row.effective_month, row.policy, row.version) for row in db.scalars(
        select(CashRolloverPolicyChange).where(
            CashRolloverPolicyChange.budget_id == budget_id,
            CashRolloverPolicyChange.version.in_(latest),
        ).order_by(CashRolloverPolicyChange.effective_month, CashRolloverPolicyChange.version)
    )]
    # Legacy and currently superseded absorb choices do not trigger a historical ledger scan.
    if not any(item.policy == "absorb_next_month" for item in history):
        return []
    zero = literal(0, type_=BigInteger)
    allocation = select(AllocationOperation.occurred_on, AllocationPosting.category_id,
                        AllocationPosting.amount_minor, zero).join(
        AllocationOperation, AllocationOperation.id == AllocationPosting.operation_id
    ).where(AllocationPosting.budget_id == budget_id, AllocationPosting.category_id.is_not(None),
            AllocationOperation.occurred_on < horizon)
    direct = select(Transaction.occurred_on, Transaction.category_id, Transaction.amount_minor,
                    case((Account.account_type == "credit", Transaction.amount_minor), else_=zero)).join(
        Account, Account.id == Transaction.account_id
    ).where(Transaction.budget_id == budget_id, Transaction.category_id.is_not(None),
            Account.is_on_budget.is_(True), Transaction.occurred_on < horizon)
    splits = select(Transaction.occurred_on, TransactionSplit.category_id, TransactionSplit.amount_minor,
                    case((Account.account_type == "credit", TransactionSplit.amount_minor), else_=zero)).select_from(
        TransactionSplit
    ).join(Transaction, Transaction.id == TransactionSplit.transaction_id).join(
        Account, Account.id == Transaction.account_id
    ).where(Transaction.budget_id == budget_id, Account.is_on_budget.is_(True), Transaction.occurred_on < horizon)
    payment = select(CreditCardReserveEvent.occurred_on, CreditCardReserveEvent.payment_category_id,
                     CreditCardReserveEvent.amount_minor, zero).where(
        CreditCardReserveEvent.budget_id == budget_id, CreditCardReserveEvent.occurred_on < horizon)
    funding = select(CreditCardReserveEvent.occurred_on, CreditCardReserveEvent.spending_category_id,
                     zero, CreditCardReserveEvent.amount_minor).where(
        CreditCardReserveEvent.budget_id == budget_id, CreditCardReserveEvent.spending_category_id.is_not(None),
        CreditCardReserveEvent.occurred_on < horizon)
    if category_ids is not None:
        allocation = allocation.where(AllocationPosting.category_id.in_(category_ids))
        direct = direct.where(Transaction.category_id.in_(category_ids))
        splits = splits.where(TransactionSplit.category_id.in_(category_ids))
        payment = payment.where(CreditCardReserveEvent.payment_category_id.in_(category_ids))
        funding = funding.where(CreditCardReserveEvent.spending_category_id.in_(category_ids))
    if account_ids is not None:
        direct = direct.where(Transaction.account_id.in_(account_ids))
        splits = splits.where(Transaction.account_id.in_(account_ids))
        payment = payment.where(CreditCardReserveEvent.credit_account_id.in_(account_ids))
        funding = funding.where(CreditCardReserveEvent.credit_account_id.in_(account_ids))
    records = db.execute(union_all(allocation, direct, splits, payment, funding).execution_options(yield_per=500))
    facts = (CategoryFact(day, category, amount, credit) for day, category, amount, credit in records)
    return project_rollover_effects(through_month=horizon, policies=history, facts=facts)
