"""Authorized, bounded observation retrieval for money-neutral import review."""
from __future__ import annotations

from datetime import date

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .access import can_access_resource, visible_resource_ids
from .budgeting_routes import require_budget_capability, transaction_visibility_conditions
from .import_matching import MAX_OBSERVATIONS, MatchObservation
from .models import Account, PayeeAlias, Transaction, User


def load_match_observations(db: Session, *, user: User, budget_id: str, account_id: str,
                            start_date: date, end_date: date) -> list[MatchObservation]:
    budget = require_budget_capability(db, user, budget_id, "view_transactions")
    require_budget_capability(db, user, budget_id, "create_transaction")
    account = db.scalar(select(Account).where(Account.id == account_id, Account.budget_id == budget.id))
    if account is None or not can_access_resource(db, user, budget, "account", account_id):
        raise HTTPException(status_code=404, detail="Account not found")
    if start_date > end_date:
        raise HTTPException(status_code=422, detail="Invalid review date range")
    rows = db.execute(select(Transaction.id, Transaction.occurred_on, Transaction.amount_minor,
                             Transaction.payee_name, Transaction.payee_id)
                      .where(*transaction_visibility_conditions(db, user, budget),
                             Transaction.account_id == account_id,
                             Transaction.occurred_on >= start_date, Transaction.occurred_on <= end_date,
                             Transaction.status == "posted")
                      .order_by(Transaction.id).limit(MAX_OBSERVATIONS + 1)).all()
    if len(rows) > MAX_OBSERVATIONS:
        raise HTTPException(status_code=422, detail="Narrow the import review date range")
    # Household aliases can improve duplicate recognition for owners and other
    # unrestricted actors. Never attach them to a resource-scoped observation:
    # an import preview must not become an alias-discovery side channel.
    scoped = (visible_resource_ids(db, user, budget, "account") is not None or
              visible_resource_ids(db, user, budget, "category") is not None)
    aliases_by_payee: dict[str, list[str]] = {}
    if not scoped:
        payee_ids = {row.payee_id for row in rows if row.payee_id is not None}
        if payee_ids:
            for payee_id, display_name in db.execute(
                select(PayeeAlias.payee_id, PayeeAlias.display_name)
                .where(PayeeAlias.payee_id.in_(payee_ids))
                .order_by(PayeeAlias.payee_id, PayeeAlias.id)
            ):
                aliases_by_payee.setdefault(payee_id, []).append(display_name)
    return [MatchObservation(row.id, row.occurred_on, row.amount_minor, row.payee_name,
                             tuple(aliases_by_payee.get(row.payee_id, ()))) for row in rows]
