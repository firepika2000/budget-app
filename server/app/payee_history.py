from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Payee, PayeeAlias, PayeeRevision


def payee_snapshot(db: Session, payee: Payee) -> dict:
    """Return only household-wide metadata; never transaction aggregates or private budget data."""
    aliases = list(db.scalars(
        select(PayeeAlias.display_name)
        .where(PayeeAlias.payee_id == payee.id)
        .order_by(PayeeAlias.display_name, PayeeAlias.id)
    ))
    return {
        "display_name": payee.display_name,
        "is_archived": bool(payee.is_archived),
        "merged_into_payee_id": payee.merged_into_payee_id,
        "aliases": aliases,
    }


def preference_snapshot(default_category_id: str | None) -> dict:
    return {"default_category_id": default_category_id}


def append_payee_revision(
    db: Session,
    *,
    payee: Payee,
    actor_user_id: str,
    action: str,
    before: dict | None,
    after: dict,
    budget_id: str | None = None,
) -> None:
    if before == after:
        return
    db.add(PayeeRevision(
        household_id=payee.household_id,
        budget_id=budget_id,
        payee_id=payee.id,
        action=action,
        actor_user_id=actor_user_id,
        before_snapshot=before,
        after_snapshot=after,
    ))
