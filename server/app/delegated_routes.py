from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .access import can_access_resource, has_capability
from .allocation import PostingInput, allocation_balance, append_operation, ready_to_assign_balance
from .budgeting_routes import lock_budget, require_budget_capability, require_version
from .database import get_db
from .dependencies import get_current_user
from .models import Category, DelegatedBudgetPolicy, DelegatedCategoryRule, Membership, User
from .schemas import DelegatedBudgetPolicyResponse, DelegatedBudgetPolicyUpsert


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/delegated-budgets")


def serialize_policy(db: Session, policy: DelegatedBudgetPolicy) -> dict:
    categories = list(db.scalars(select(Category).where(
        Category.budget_id == policy.budget_id,
        Category.delegated_user_id == policy.user_id,
        Category.is_archived.is_(False),
    )))
    pool_available = max(allocation_balance(db, policy.budget_id, category_id=policy.pool_category_id), 0)
    rules = list(db.scalars(select(DelegatedCategoryRule).where(
        DelegatedCategoryRule.policy_id == policy.id
    )))
    return {
        "id": policy.id,
        "budget_id": policy.budget_id,
        "user_id": policy.user_id,
        "pool_category_id": policy.pool_category_id,
        "authority_minor": policy.authority_minor,
        "assigned_minor": max(policy.authority_minor - pool_available, 0),
        "available_to_assign_minor": pool_available,
        "allow_category_creation": policy.allow_category_creation,
        "allow_reallocation": policy.allow_reallocation,
        "rules": rules,
    }


@router.get("", response_model=list[DelegatedBudgetPolicyResponse])
def list_delegated_budgets(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    require_budget_capability(db, user, budget_id, "manage_allowances")
    policies = list(db.scalars(select(DelegatedBudgetPolicy).where(
        DelegatedBudgetPolicy.budget_id == budget_id
    ).order_by(DelegatedBudgetPolicy.user_id)))
    return [serialize_policy(db, policy) for policy in policies]


@router.get("/me", response_model=DelegatedBudgetPolicyResponse)
def get_my_delegated_budget(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "view_categories")
    policy = db.scalar(select(DelegatedBudgetPolicy).where(
        DelegatedBudgetPolicy.budget_id == budget.id,
        DelegatedBudgetPolicy.user_id == user.id,
    ))
    if policy is None:
        raise HTTPException(status_code=404, detail="Delegated budget not found")
    return serialize_policy(db, policy)


@router.put("/{user_id}", response_model=DelegatedBudgetPolicyResponse)
def upsert_delegated_budget(
    budget_id: str,
    user_id: str,
    body: DelegatedBudgetPolicyUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_budget_capability(db, user, budget_id, "manage_allowances")
    if user_id != body.user_id:
        raise HTTPException(status_code=422, detail="User path and body must match")
    membership = db.scalar(select(Membership).where(
        Membership.household_id == budget.household_id,
        Membership.user_id == user_id,
        Membership.is_active.is_(True),
    ))
    pool = db.get(Category, body.pool_category_id)
    if membership is None or membership.role == "owner":
        raise HTTPException(status_code=422, detail="Delegated user must be an active non-owner member")
    if pool is None or pool.budget_id != budget_id or pool.delegated_user_id != user_id or pool.is_archived:
        raise HTTPException(status_code=422, detail="Pool category must belong to the delegated member")
    rule_categories = {item.category_id: db.get(Category, item.category_id) for item in body.rules}
    if any(category is None or category.budget_id != budget_id or category.delegated_user_id != user_id for category in rule_categories.values()):
        raise HTTPException(status_code=422, detail="Rules may only target the delegated member's categories")
    locked_budget = lock_budget(db, budget_id)
    require_version(locked_budget, body.expected_allocation_version)
    controlled_category_ids = list(db.scalars(select(Category.id).where(
        Category.budget_id == budget_id,
        Category.delegated_user_id == user_id,
    )))
    controlled_allocation = sum(
        allocation_balance(db, budget_id, category_id=category_id)
        for category_id in controlled_category_ids
    )
    funding_delta = body.authority_minor - controlled_allocation
    pool_allocation = allocation_balance(db, budget_id, category_id=body.pool_category_id)
    if funding_delta > 0 and ready_to_assign_balance(db, budget_id) < funding_delta:
        raise HTTPException(status_code=409, detail="Not enough household Ready to Assign to fund this authority")
    if funding_delta < 0 and pool_allocation < -funding_delta:
        raise HTTPException(status_code=409, detail="Move money back to the delegated pool before reducing authority")
    policy = db.scalar(select(DelegatedBudgetPolicy).where(
        DelegatedBudgetPolicy.budget_id == budget_id,
        DelegatedBudgetPolicy.user_id == user_id,
    ))
    if policy is None:
        policy = DelegatedBudgetPolicy(
            budget_id=budget_id,
            user_id=user_id,
            pool_category_id=body.pool_category_id,
            authority_minor=body.authority_minor,
            allow_category_creation=body.allow_category_creation,
            allow_reallocation=body.allow_reallocation,
            created_by_user_id=user.id,
        )
        db.add(policy)
        db.flush()
    policy.pool_category_id = body.pool_category_id
    policy.authority_minor = body.authority_minor
    policy.allow_category_creation = body.allow_category_creation
    policy.allow_reallocation = body.allow_reallocation
    db.execute(delete(DelegatedCategoryRule).where(DelegatedCategoryRule.policy_id == policy.id))
    for rule in body.rules:
        db.add(DelegatedCategoryRule(policy_id=policy.id, **rule.model_dump()))
    if funding_delta != 0:
        append_operation(
            db,
            budget=locked_budget,
            actor=user,
            occurred_on=date.today(),
            kind="delegated_authority",
            note=f"Set delegated authority for member {user_id}",
            postings=[
                PostingInput(bucket="ready_to_assign", amount_minor=-funding_delta),
                PostingInput(bucket="category", category_id=body.pool_category_id, amount_minor=funding_delta),
            ],
        )
    db.commit()
    return serialize_policy(db, policy)
