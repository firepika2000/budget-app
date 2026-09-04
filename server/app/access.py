from __future__ import annotations

from sqlalchemy import Select, exists, or_, select
from sqlalchemy.orm import Session

from .models import (
    Budget,
    BudgetAccessProfile,
    BudgetGrant,
    BudgetPermission,
    CapabilityGrant,
    Household,
    Membership,
    ResourceGrant,
    User,
)


ALL_CAPABILITIES = {
    "view_budget", "view_accounts", "view_account_balances", "view_categories",
    "view_transactions", "view_reports", "view_allocation_history", "create_transaction",
    "request_money", "assign_money", "move_money", "reconcile_account",
    "manage_budget_structure", "manage_planning", "approve_request",
}

PERMISSION_LEVEL = {
    BudgetPermission.VIEW.value: 10,
    BudgetPermission.CONTRIBUTE.value: 20,
    BudgetPermission.MANAGE.value: 30,
}

LEGACY_CAPABILITIES = {
    "view": {"view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports", "view_allocation_history"},
    "contribute": {
        "view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports", "view_allocation_history",
        "create_transaction", "request_money",
    },
    "manage": {
        "view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports", "view_allocation_history",
        "create_transaction", "request_money", "assign_money", "move_money", "reconcile_account",
        "manage_budget_structure", "manage_planning", "approve_request",
    },
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


def access_profile(db: Session, user: User, budget: Budget) -> BudgetAccessProfile | None:
    if is_household_owner(db, user, budget.household_id):
        return None
    return db.scalar(select(BudgetAccessProfile).where(
        BudgetAccessProfile.budget_id == budget.id,
        BudgetAccessProfile.user_id == user.id,
    ))


def has_capability(db: Session, user: User, budget: Budget, capability: str) -> bool:
    return capability in effective_capabilities(db, user, budget)


def effective_capabilities(db: Session, user: User, budget: Budget) -> set[str]:
    if is_household_owner(db, user, budget.household_id):
        return set(ALL_CAPABILITIES)
    membership = db.scalar(active_membership_query(user.id, budget.household_id))
    if membership is None:
        return set()
    profile = access_profile(db, user, budget)
    if profile is not None:
        return set(db.scalars(select(CapabilityGrant.capability).where(
            CapabilityGrant.budget_id == budget.id,
            CapabilityGrant.user_id == user.id,
        )))
    grant = db.scalar(select(BudgetGrant).where(
        BudgetGrant.budget_id == budget.id,
        BudgetGrant.user_id == user.id,
    ))
    return set() if grant is None else set(LEGACY_CAPABILITIES.get(grant.permission, set()))


def visible_resource_ids(
    db: Session,
    user: User,
    budget: Budget,
    resource_type: str,
) -> set[str] | None:
    """Return None for unrestricted access, otherwise the exact visible ID set."""
    if is_household_owner(db, user, budget.household_id):
        return None
    profile = access_profile(db, user, budget)
    if profile is None:
        return None
    restricted = (
        profile.restrict_accounts if resource_type == "account" else profile.restrict_categories
    )
    if not restricted:
        return None
    return set(db.scalars(select(ResourceGrant.resource_id).where(
        ResourceGrant.budget_id == budget.id,
        ResourceGrant.user_id == user.id,
        ResourceGrant.resource_type == resource_type,
    )))


def can_access_resource(
    db: Session,
    user: User,
    budget: Budget,
    resource_type: str,
    resource_id: str,
) -> bool:
    allowed = visible_resource_ids(db, user, budget, resource_type)
    return allowed is None or resource_id in allowed
