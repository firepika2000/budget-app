"""Authorized, bounded observation retrieval for money-neutral import review."""
from __future__ import annotations

from datetime import date

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .access import can_access_resource
from .budgeting_routes import require_budget_capability, transaction_visibility_conditions
from .import_matching import MAX_OBSERVATIONS, MatchObservation
from .models import Account, Transaction, User


def load_match_observations(db: Session, *, user: User, budget_id: str, account_id: str,
                            start_date: date, end_date: date) -> list[MatchObservation]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    require_budget_capability(db, user, budget_id, "create_transaction")
    account = db.scalar(select(Account).where(Account.id == account_id, Account.budget_id == budget.id))
    if account is None or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    if start_date > end_date:
        raise HTTPException(status_code=422, detail="Invalid review date range")
    rows = db.execute(select(Transaction.id, Transaction.occurred_on, Transaction.amount_minor, Transaction.payee_name)
                      .where(*transaction_visibility_conditions(db, user, budget),
                             Transaction.account_id == account_id,
                             Transaction.occurred_on >= start_date, Transaction.occurred_on <= end_date,
                             Transaction.status == "posted")
                      .order_by(Transaction.id).limit(MAX_OBSERVATIONS + 1)).all()
    if len(rows) > MAX_OBSERVATIONS:
        raise HTTPException(status_code=422, detail="Narrow the import review date range")
    return [MatchObservation(*row) for row in rows]
