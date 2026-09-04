import calendar
from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from .access import find_visible_budget, has_capability
from .allocation import PostingInput, append_operation, category_available_balance, lock_budget, require_version
from .database import get_db
from .dependencies import get_current_user
from .models import (
    AllowanceIssuance,
    AllowancePlan,
    AllowanceSplit,
    BudgetAccessProfile,
    Category,
    Membership,
    ResourceGrant,
    User,
)
from .schemas import (
    AllowanceIssueRequest,
    AllowanceIssuanceResponse,
    AllowancePlanCreate,
    AllowancePlanResponse,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/allowances")


def advance_issue_date(value: date, unit: str, interval: int) -> date:
    if unit == "week":
        return value + timedelta(weeks=interval)
    month_index = value.month - 1 + interval
    year = value.year + month_index // 12
    month = month_index % 12 + 1
    day = min(value.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def serialize_plan(plan: AllowancePlan, *, reveal_source: bool = True) -> dict:
    return {
        "id": plan.id,
        "budget_id": plan.budget_id,
        "delegated_user_id": plan.delegated_user_id,
        "source_category_id": plan.source_category_id if reveal_source else None,
        "name": plan.name,
        "amount_minor": plan.amount_minor,
        "next_issue_date": plan.next_issue_date,
        "recurrence_unit": plan.recurrence_unit,
        "interval_count": plan.interval_count,
        "rollover_policy": plan.rollover_policy,
        "is_active": plan.is_active,
        "splits": plan.splits,
    }


@router.get("", response_model=list[AllowancePlanResponse])
def list_allowance_plans(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    query = select(AllowancePlan).options(selectinload(AllowancePlan.splits)).where(
        AllowancePlan.budget_id == budget_id,
        AllowancePlan.is_active.is_(True),
    )
    can_manage = has_capability(db, user, budget, "manage_allowances")
    if not can_manage:
        query = query.where(AllowancePlan.delegated_user_id == user.id)
    return [
        serialize_plan(plan, reveal_source=can_manage)
        for plan in db.scalars(query.order_by(AllowancePlan.next_issue_date))
    ]


@router.post("", response_model=AllowancePlanResponse, status_code=status.HTTP_201_CREATED)
def create_allowance_plan(
    budget_id: str,
    body: AllowancePlanCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, "manage_allowances"):
        raise HTTPException(status_code=403, detail="Insufficient capability")
    member = db.scalar(select(Membership).where(
        Membership.household_id == budget.household_id,
        Membership.user_id == body.delegated_user_id,
        Membership.is_active.is_(True),
    ))
    if member is None:
        raise HTTPException(status_code=422, detail="Delegated user must be an active household member")
    category_ids = [body.source_category_id] + [split.destination_category_id for split in body.splits]
    categories = {category.id: category for category in db.scalars(select(Category).where(
        Category.budget_id == budget_id,
        Category.id.in_(category_ids),
        Category.is_archived.is_(False),
    ))}
    if set(category_ids) != set(categories) or body.source_category_id in {
        split.destination_category_id for split in body.splits
    }:
        raise HTTPException(status_code=422, detail="Invalid allowance categories")
    if any(
        categories[split.destination_category_id].delegated_user_id != body.delegated_user_id
        for split in body.splits
    ):
        raise HTTPException(status_code=422, detail="Allowance destinations must be delegated to the recipient")
    destination_ids = [split.destination_category_id for split in body.splits]
    recipient_profile = db.scalar(select(BudgetAccessProfile).where(
        BudgetAccessProfile.budget_id == budget_id,
        BudgetAccessProfile.user_id == body.delegated_user_id,
    ))
    if recipient_profile is not None and recipient_profile.restrict_categories:
        recipient_visible = set(db.scalars(select(ResourceGrant.resource_id).where(
            ResourceGrant.budget_id == budget_id,
            ResourceGrant.user_id == body.delegated_user_id,
            ResourceGrant.resource_type == "category",
        )))
        if not set(destination_ids).issubset(recipient_visible):
            raise HTTPException(status_code=422, detail="Allowance destinations must be visible to the recipient")
    already_used = db.scalar(select(AllowanceSplit.id).join(
        AllowancePlan, AllowancePlan.id == AllowanceSplit.plan_id
    ).where(
        AllowanceSplit.destination_category_id.in_(destination_ids),
        AllowancePlan.is_active.is_(True),
    ))
    if already_used is not None:
        raise HTTPException(status_code=409, detail="A destination already belongs to an active allowance plan")
    values = body.model_dump(exclude={"splits"})
    plan = AllowancePlan(budget_id=budget_id, created_by_user_id=user.id, **values)
    plan.splits = [AllowanceSplit(**split.model_dump()) for split in body.splits]
    db.add(plan)
    db.commit()
    db.refresh(plan)
    return serialize_plan(plan)


@router.delete("/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_allowance_plan(
    budget_id: str,
    plan_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, "manage_allowances"):
        raise HTTPException(status_code=403, detail="Insufficient capability")
    plan = db.get(AllowancePlan, plan_id)
    if plan is None or plan.budget_id != budget_id or not plan.is_active:
        raise HTTPException(status_code=404, detail="Allowance plan not found")
    plan.is_active = False
    db.commit()


@router.post("/{plan_id}/issue", response_model=AllowanceIssuanceResponse)
def issue_allowance(
    budget_id: str,
    plan_id: str,
    body: AllowanceIssueRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, "manage_allowances"):
        raise HTTPException(status_code=403, detail="Insufficient capability")
    plan = db.scalar(select(AllowancePlan).options(selectinload(AllowancePlan.splits)).where(
        AllowancePlan.id == plan_id,
        AllowancePlan.budget_id == budget_id,
    ).with_for_update())
    if plan is None or not plan.is_active:
        raise HTTPException(status_code=404, detail="Allowance plan not found")
    if body.issue_date != plan.next_issue_date:
        raise HTTPException(status_code=409, detail="Allowance issue date has changed")
    if body.issue_date > date.today():
        raise HTTPException(status_code=422, detail="Future allowances remain planned until their issue date")

    locked_budget = lock_budget(db, budget_id)
    require_version(locked_budget, body.expected_allocation_version)
    reclaim_by_category: dict[str, int] = {}
    if plan.rollover_policy == "use_it_or_lose_it":
        reclaim_by_category = {
            split.destination_category_id: max(category_available_balance(
                db, budget_id, split.destination_category_id, through=body.issue_date
            ), 0)
            for split in plan.splits
        }
    reclaimed = sum(reclaim_by_category.values())
    source_available = category_available_balance(
        db, budget_id, plan.source_category_id, through=body.issue_date
    )
    if source_available + reclaimed < plan.amount_minor:
        raise HTTPException(status_code=409, detail="Allowance source category has insufficient funds")

    postings: list[PostingInput] = []
    if reclaimed:
        postings.append(PostingInput(
            bucket="category", category_id=plan.source_category_id, amount_minor=reclaimed
        ))
        postings.extend(
            PostingInput(
                bucket="category", category_id=category_id, amount_minor=-amount
            )
            for category_id, amount in reclaim_by_category.items()
            if amount
        )
    postings.append(PostingInput(
        bucket="category", category_id=plan.source_category_id, amount_minor=-plan.amount_minor
    ))
    postings.extend(
        PostingInput(
            bucket="category",
            category_id=split.destination_category_id,
            amount_minor=split.amount_minor,
        )
        for split in plan.splits
    )
    operation = append_operation(
        db,
        budget=locked_budget,
        actor=user,
        occurred_on=body.issue_date,
        kind="allowance_issuance",
        note=plan.name,
        source="allowance",
        postings=postings,
    )
    db.flush()
    issuance = AllowanceIssuance(
        plan_id=plan.id,
        budget_id=budget_id,
        issued_on=body.issue_date,
        amount_minor=plan.amount_minor,
        reclaimed_minor=reclaimed,
        allocation_operation_id=operation.id,
        actor_user_id=user.id,
    )
    db.add(issuance)
    plan.next_issue_date = advance_issue_date(
        plan.next_issue_date, plan.recurrence_unit, plan.interval_count
    )
    db.commit()
    db.refresh(issuance)
    return {
        "id": issuance.id,
        "plan_id": issuance.plan_id,
        "budget_id": issuance.budget_id,
        "issued_on": issuance.issued_on,
        "amount_minor": issuance.amount_minor,
        "reclaimed_minor": issuance.reclaimed_minor,
        "allocation_operation_id": issuance.allocation_operation_id,
        "actor_user_id": issuance.actor_user_id,
        "created_at": issuance.created_at,
        "next_issue_date": plan.next_issue_date,
    }


@router.get("/{plan_id}/issuances", response_model=list[AllowanceIssuanceResponse])
def list_allowance_issuances(
    budget_id: str,
    plan_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    plan = db.get(AllowancePlan, plan_id)
    if plan is None or plan.budget_id != budget_id or (
        plan.delegated_user_id != user.id and not has_capability(db, user, budget, "manage_allowances")
    ):
        raise HTTPException(status_code=404, detail="Allowance plan not found")
    issuances = list(db.scalars(select(AllowanceIssuance).where(
        AllowanceIssuance.plan_id == plan_id
    ).order_by(AllowanceIssuance.issued_on.desc())))
    return [{
        "id": item.id,
        "plan_id": item.plan_id,
        "budget_id": item.budget_id,
        "issued_on": item.issued_on,
        "amount_minor": item.amount_minor,
        "reclaimed_minor": item.reclaimed_minor,
        "allocation_operation_id": item.allocation_operation_id,
        "actor_user_id": item.actor_user_id,
        "created_at": item.created_at,
        "next_issue_date": plan.next_issue_date,
    } for item in issuances]
