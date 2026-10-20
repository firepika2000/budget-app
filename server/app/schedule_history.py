from __future__ import annotations

from sqlalchemy.orm import Session

from .models import ScheduledTransaction, ScheduledTransactionRevision


def schedule_snapshot(schedule: ScheduledTransaction) -> dict:
    return {
        "account_id": schedule.account_id, "destination_account_id": schedule.destination_account_id,
        "category_id": schedule.category_id, "payee_id": schedule.payee_id, "name": schedule.name,
        "amount_minor": schedule.amount_minor, "next_date": schedule.next_date.isoformat(),
        "recurrence_unit": schedule.recurrence_unit, "interval_count": schedule.interval_count,
        "end_date": schedule.end_date.isoformat() if schedule.end_date else None,
        "remaining_occurrences": schedule.remaining_occurrences, "memo": schedule.memo,
        "financial_classification": schedule.financial_classification, "is_active": schedule.is_active,
        "last_realized_on": schedule.last_realized_on.isoformat() if schedule.last_realized_on else None,
    }


def append_schedule_revision(db: Session, schedule: ScheduledTransaction, action: str, actor_id: str,
                             before: dict | None, after: dict | None,
                             transaction_ids: list[str] | None = None) -> ScheduledTransactionRevision:
    revision = ScheduledTransactionRevision(
        budget_id=schedule.budget_id, schedule_id=schedule.id, account_id=schedule.account_id,
        destination_account_id=schedule.destination_account_id, category_id=schedule.category_id,
        before_account_id=before.get("account_id") if before else None,
        before_destination_account_id=before.get("destination_account_id") if before else None,
        before_category_id=before.get("category_id") if before else None,
        action=action, actor_user_id=actor_id, before_snapshot=before, after_snapshot=after,
        transaction_ids=transaction_ids,
    )
    db.add(revision)
    return revision
