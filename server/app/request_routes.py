from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from .access import can_access_resource, find_visible_budget, has_capability
from .allocation import PostingInput, append_operation, category_available_balance, lock_budget
from .database import get_db
from .dependencies import get_current_user
from .models import Category, FinancialRequest, RequestAction, User
from .schemas import (
    FinancialRequestCancel,
    FinancialRequestCreate,
    FinancialRequestDecision,
    FinancialRequestResponse,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}/requests")


def require_request_capability(
    db: Session, user: User, budget_id: str, capability: str
):
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, capability):
        raise HTTPException(status_code=403, detail="Insufficient capability")
    return budget


def serialize_request(db: Session, item: FinancialRequest) -> dict:
    actions = list(db.scalars(select(RequestAction).where(
        RequestAction.request_id == item.id
    ).order_by(RequestAction.created_at, RequestAction.id)))
    return {
        "id": item.id,
        "household_id": item.household_id,
        "budget_id": item.budget_id,
        "requester_user_id": item.requester_user_id,
        "request_type": item.request_type,
        "destination_category_id": item.destination_category_id,
        "requested_amount_minor": item.requested_amount_minor,
        "reason": item.reason,
        "status": item.status,
        "version": item.version,
        "approved_amount_minor": item.approved_amount_minor,
        "source_category_id": item.source_category_id,
        "allocation_operation_id": item.allocation_operation_id,
        "created_at": item.created_at,
        "resolved_at": item.resolved_at,
        "actions": actions,
    }


@router.post("", response_model=FinancialRequestResponse, status_code=status.HTTP_201_CREATED)
def create_request(
    budget_id: str,
    body: FinancialRequestCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_request_capability(db, user, budget_id, "request_money")
    destination = db.get(Category, body.destination_category_id)
    if (
        destination is None
        or destination.budget_id != budget_id
        or destination.is_archived
        or not can_access_resource(db, user, budget, "category", destination.id)
    ):
        raise HTTPException(status_code=422, detail="Invalid destination category")
    item = FinancialRequest(
        household_id=budget.household_id,
        budget_id=budget_id,
        requester_user_id=user.id,
        **body.model_dump(),
    )
    db.add(item)
    db.flush()
    db.add(RequestAction(
        request_id=item.id,
        actor_user_id=user.id,
        action="submitted",
        amount_minor=body.requested_amount_minor,
        note=body.reason,
    ))
    db.commit()
    db.refresh(item)
    return serialize_request(db, item)


@router.get("", response_model=list[FinancialRequestResponse])
def list_requests(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    query = select(FinancialRequest).where(FinancialRequest.budget_id == budget_id)
    if not has_capability(db, user, budget, "approve_request"):
        if not has_capability(db, user, budget, "request_money"):
            raise HTTPException(status_code=403, detail="Insufficient capability")
        query = query.where(FinancialRequest.requester_user_id == user.id)
    items = list(db.scalars(query.order_by(FinancialRequest.created_at.desc())))
    return [serialize_request(db, item) for item in items]


@router.post("/{request_id}/decision", response_model=FinancialRequestResponse)
def decide_request(
    budget_id: str,
    request_id: str,
    body: FinancialRequestDecision,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = require_request_capability(db, user, budget_id, "approve_request")
    item = db.scalar(select(FinancialRequest).where(
        FinancialRequest.id == request_id,
        FinancialRequest.budget_id == budget_id,
    ).with_for_update())
    if item is None:
        raise HTTPException(status_code=404, detail="Request not found")
    if item.status != "pending" or item.version != body.expected_request_version:
        raise HTTPException(status_code=409, detail="Request has already changed")

    now = datetime.now(timezone.utc)
    action_amount = None
    if body.decision == "approve":
        approved = body.approved_amount_minor or 0
        if approved > item.requested_amount_minor:
            raise HTTPException(status_code=422, detail="Approved amount exceeds request")
        source = db.get(Category, body.source_category_id)
        destination = db.get(Category, item.destination_category_id)
        if any(
            category is None or category.budget_id != budget_id or category.is_archived
            for category in (source, destination)
        ) or source.id == destination.id or any(
            not can_access_resource(db, user, budget, "category", category.id)
            for category in (source, destination)
        ):
            raise HTTPException(status_code=422, detail="Invalid approval categories")
        locked_budget = lock_budget(db, budget_id)
        if category_available_balance(db, budget_id, source.id, through=date.today()) < approved:
            raise HTTPException(status_code=409, detail="Source category has insufficient funds")
        operation = append_operation(
            db,
            budget=locked_budget,
            actor=user,
            occurred_on=date.today(),
            kind="request_approval",
            note=body.note or item.reason,
            source="approval",
            postings=[
                PostingInput(bucket="category", category_id=source.id, amount_minor=-approved),
                PostingInput(bucket="category", category_id=destination.id, amount_minor=approved),
            ],
        )
        db.flush()
        item.approved_amount_minor = approved
        item.source_category_id = source.id
        item.allocation_operation_id = operation.id
        item.status = "approved" if approved == item.requested_amount_minor else "partially_approved"
        item.resolved_at = now
        action_amount = approved
    elif body.decision == "reject":
        item.status = "rejected"
        item.resolved_at = now
    else:
        item.status = "changes_requested"
    item.version += 1
    db.add(RequestAction(
        request_id=item.id,
        actor_user_id=user.id,
        action=item.status,
        amount_minor=action_amount,
        note=body.note,
    ))
    db.commit()
    db.refresh(item)
    return serialize_request(db, item)


@router.post("/{request_id}/cancel", response_model=FinancialRequestResponse)
def cancel_request(
    budget_id: str,
    request_id: str,
    body: FinancialRequestCancel,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    require_request_capability(db, user, budget_id, "request_money")
    item = db.scalar(select(FinancialRequest).where(
        FinancialRequest.id == request_id,
        FinancialRequest.budget_id == budget_id,
    ).with_for_update())
    if item is None or item.requester_user_id != user.id:
        raise HTTPException(status_code=404, detail="Request not found")
    if item.status not in ("pending", "changes_requested") or item.version != body.expected_request_version:
        raise HTTPException(status_code=409, detail="Request has already changed")
    item.status = "cancelled"
    item.version += 1
    item.resolved_at = datetime.now(timezone.utc)
    db.add(RequestAction(
        request_id=item.id,
        actor_user_id=user.id,
        action="cancelled",
        note=body.note,
    ))
    db.commit()
    db.refresh(item)
    return serialize_request(db, item)
