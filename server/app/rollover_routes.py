"""Owner-controlled prospective cash policy; effects remain derived, never posted."""
from __future__ import annotations

from datetime import date, datetime
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .access import find_visible_budget, is_household_owner
from .allocation import lock_budget, ready_to_assign_balance, require_version
from .database import get_db
from .dependencies import get_current_user
from .models import Budget, CashRolloverPolicyChange, User

router = APIRouter(prefix="/api/v1/budgets/{budget_id}/cash-rollover-policy")
Policy = Literal["carry_category_deficit", "absorb_next_month"]


class PolicySelection(BaseModel):
    policy: Policy
    effective_month: date
    expected_policy_version: int = Field(ge=0)
    expected_allocation_version: int = Field(ge=0)


class PendingPolicy(BaseModel):
    effective_month: date
    policy: Policy
    version: int


class PolicyObservation(BaseModel):
    current_month: date
    current_policy: Policy
    policy_version: int
    allocation_version: int
    pending: list[PendingPolicy]


class PolicyAudit(PendingPolicy):
    id: str
    source: Literal["legacy_migration", "budget_creation", "user_selection"]
    actor_user_id: Optional[str]
    created_at: datetime


class PolicyAuditPage(BaseModel):
    items: list[PolicyAudit]
    next_before_version: Optional[int]


def require_owner(db: Session, user: User, budget_id: str) -> Budget:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(404, "Budget not found")
    if not is_household_owner(db, user, budget.household_id):
        raise HTTPException(403, "Only the household owner can manage the budget's cash rollover policy")
    return budget


def history(db: Session, budget_id: str) -> list[CashRolloverPolicyChange]:
    latest = select(func.max(CashRolloverPolicyChange.version)).where(
        CashRolloverPolicyChange.budget_id == budget_id,
    ).group_by(CashRolloverPolicyChange.effective_month)
    return list(db.scalars(select(CashRolloverPolicyChange).where(
        CashRolloverPolicyChange.budget_id == budget_id,
        CashRolloverPolicyChange.version.in_(latest),
    ).order_by(CashRolloverPolicyChange.effective_month, CashRolloverPolicyChange.version)))


def observation(db: Session, budget: Budget) -> dict:
    rows = history(db, budget.id)
    month = date.today().replace(day=1)
    current = next((row for row in reversed(rows) if row.effective_month <= month), None)
    pending = {row.effective_month: row for row in rows if row.effective_month > month}
    return {
        "current_month": month, "current_policy": current.policy if current else "carry_category_deficit",
        "policy_version": max((row.version for row in rows), default=0),
        "allocation_version": budget.allocation_version,
        "pending": [{"effective_month": row.effective_month, "policy": row.policy, "version": row.version}
                    for row in pending.values()],
    }


@router.get("", response_model=PolicyObservation)
def get_policy(budget_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    return observation(db, require_owner(db, user, budget_id))


@router.get("/history", response_model=PolicyAuditPage)
def get_history(budget_id: str, before_version: Optional[int] = Query(default=None, ge=0),
                limit: int = Query(default=50, ge=1, le=100),
                user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    require_owner(db, user, budget_id)
    query = select(CashRolloverPolicyChange).where(CashRolloverPolicyChange.budget_id == budget_id)
    if before_version is not None:
        query = query.where(CashRolloverPolicyChange.version < before_version)
    rows = list(db.scalars(query.order_by(CashRolloverPolicyChange.version.desc()).limit(limit + 1)))
    page = rows[:limit]
    return {"items": [{"id": row.id, "effective_month": row.effective_month, "policy": row.policy,
                        "version": row.version, "source": row.source, "actor_user_id": row.actor_user_id,
                        "created_at": row.created_at} for row in page],
            "next_before_version": page[-1].version if len(rows) > limit else None}


@router.put("", response_model=PolicyObservation)
def select_policy(budget_id: str, body: PolicySelection,
                  user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    require_owner(db, user, budget_id)
    budget = lock_budget(db, budget_id)
    require_version(budget, body.expected_allocation_version)
    rows = history(db, budget_id)
    version = max((row.version for row in rows), default=0)
    if body.expected_policy_version != version:
        raise HTTPException(409, "Cash rollover policy changed. Refresh before trying again.")
    if body.effective_month.day != 1 or body.effective_month <= date.today().replace(day=1):
        raise HTTPException(422, "A policy change must begin on the first day of a future month")
    effective = next((row.policy for row in reversed(rows) if row.effective_month <= body.effective_month), "carry_category_deficit")
    if effective == body.policy:
        return observation(db, budget)
    # Budgets created during gated integration may lack the migration's legacy baseline.
    # Preserve that existing behavior explicitly before recording their first real selection.
    if not rows:
        db.add(CashRolloverPolicyChange(budget_id=budget_id, effective_month=date.min,
            policy="carry_category_deficit", version=0, source="legacy_migration", actor_user_id=None))
    db.add(CashRolloverPolicyChange(budget_id=budget_id, effective_month=body.effective_month,
        policy=body.policy, version=version + 1, source="user_selection", actor_user_id=user.id))
    budget.allocation_version += 1
    try:
        db.flush()
        if not -(2**63) <= ready_to_assign_balance(db, budget_id) <= 2**63 - 1:
            raise OverflowError("Unassigned exceeds supported minor units")
    except (ValueError, OverflowError):
        db.rollback()
        raise HTTPException(422, "This policy would exceed the supported monetary range")
    db.commit()
    return observation(db, budget)
