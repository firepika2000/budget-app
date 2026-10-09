from __future__ import annotations

from sqlalchemy.orm import Session

from .models import AllowancePlan, AllowancePlanRevision


def allowance_plan_snapshot(plan: AllowancePlan) -> dict:
    return {
        "delegated_user_id": plan.delegated_user_id,
        "source_category_id": plan.source_category_id,
        "name": plan.name,
        "amount_minor": plan.amount_minor,
        "next_issue_date": plan.next_issue_date.isoformat(),
        "recurrence_unit": plan.recurrence_unit,
        "interval_count": plan.interval_count,
        "rollover_policy": plan.rollover_policy,
        "is_active": bool(plan.is_active),
        "splits": [
            {
                "destination_category_id": split.destination_category_id,
                "amount_minor": split.amount_minor,
            }
            for split in sorted(plan.splits, key=lambda item: (item.destination_category_id, item.id))
        ],
    }


def append_allowance_plan_revision(
    db: Session,
    *,
    plan: AllowancePlan,
    actor_user_id: str,
    action: str,
    before: dict | None,
    after: dict,
) -> None:
    if before == after:
        return
    db.add(AllowancePlanRevision(
        budget_id=plan.budget_id,
        plan_id=plan.id,
        action=action,
        actor_user_id=actor_user_id,
        before_snapshot=before,
        after_snapshot=after,
    ))
