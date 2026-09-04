from __future__ import annotations

from sqlalchemy import Select, exists, or_, select
from sqlalchemy.orm import Session

from .models import Budget, BudgetGrant, BudgetPermission, Household, Membership, User


PERMISSION_LEVEL = {
    BudgetPermission.VIEW.value: 10,
    BudgetPermission.CONTRIBUTE.value: 20,
    BudgetPermission.MANAGE.value: 30,
}


def active_membership_query(user_id: str, household_id: str) -> Select[tuple[Membership]]:
    return select(Membership).where(
        Membership.user_id == user_id,
        Membership.household_id == household_id,
        Membership.is_active.is_(True),
    )


def is_household_owner(db: Session, user: User, household_id: str) -> bool:
    return db.scalar(
        select(exists().where(
            Household.id == household_id,
            Household.owner_user_id == user.id,
        ))
    ) is True


def visible_budgets_query(user: User) -> Select[tuple[Budget]]:
    owner_household = exists().where(
        Household.id == Budget.household_id,
        Household.owner_user_id == user.id,
    )
    active_membership = exists().where(
        Membership.household_id == Budget.household_id,
        Membership.user_id == user.id,
        Membership.is_active.is_(True),
    )
    explicit_grant = exists().where(
        BudgetGrant.budget_id == Budget.id,
        BudgetGrant.user_id == user.id,
    )
    return select(Budget).where(or_(owner_household, active_membership & explicit_grant))


def find_visible_budget(db: Session, user: User, budget_id: str) -> Budget | None:
    return db.scalar(visible_budgets_query(user).where(Budget.id == budget_id))


def has_budget_permission(
    db: Session,
    user: User,
    budget: Budget,
    required: BudgetPermission,
) -> bool:
    if is_household_owner(db, user, budget.household_id):
        return True
    membership = db.scalar(active_membership_query(user.id, budget.household_id))
    if membership is None:
        return False
    grant = db.scalar(select(BudgetGrant).where(
        BudgetGrant.budget_id == budget.id,
        BudgetGrant.user_id == user.id,
    ))
    return grant is not None and PERMISSION_LEVEL[grant.permission] >= PERMISSION_LEVEL[required.value]


def effective_budget_permission(db: Session, user: User, budget: Budget) -> str | None:
    if is_household_owner(db, user, budget.household_id):
        return "owner"
    membership = db.scalar(active_membership_query(user.id, budget.household_id))
    if membership is None:
        return None
    grant = db.scalar(select(BudgetGrant).where(
        BudgetGrant.budget_id == budget.id,
        BudgetGrant.user_id == user.id,
    ))
    return grant.permission if grant is not None else None
