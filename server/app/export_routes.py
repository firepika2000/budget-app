from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.encoders import jsonable_encoder
from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

from .access import find_visible_budget, has_capability
from .database import get_db
from .dependencies import get_current_user
from .models import (
    Account,
    AllocationOperation,
    AllocationPosting,
    AllowanceIssuance,
    AllowancePlan,
    AllowanceSplit,
    BudgetAccessProfile,
    CapabilityGrant,
    Category,
    CategoryGroup,
    CategoryTarget,
    CreditCardReserveEvent,
    FinancialRequest,
    MonthlyAssignment,
    Membership,
    RequestAction,
    ResourceGrant,
    ScheduledTransaction,
    Transaction,
    TransactionSplit,
    User,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


def row_data(item) -> dict:
    return {
        attribute.key: getattr(item, attribute.key)
        for attribute in inspect(item).mapper.column_attrs
    }


@router.get("/export.json")
def export_budget_json(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, "export_data"):
        raise HTTPException(status_code=403, detail="Insufficient capability")

    operations = list(db.scalars(select(AllocationOperation).where(
        AllocationOperation.budget_id == budget_id
    )))
    operation_ids = [item.id for item in operations]
    transactions = list(db.scalars(select(Transaction).where(Transaction.budget_id == budget_id)))
    transaction_ids = [item.id for item in transactions]
    requests = list(db.scalars(select(FinancialRequest).where(FinancialRequest.budget_id == budget_id)))
    request_ids = [item.id for item in requests]
    plans = list(db.scalars(select(AllowancePlan).where(AllowancePlan.budget_id == budget_id)))
    plan_ids = [item.id for item in plans]

    payload = {
        "schema_version": 1,
        "exported_at": datetime.now(timezone.utc),
        "budget": row_data(budget),
        "household_members": [row_data(item) for item in db.scalars(select(Membership).where(
            Membership.household_id == budget.household_id
        ))],
        "user_directory": [{
            "id": item.id,
            "email": item.email,
            "display_name": item.display_name,
            "created_at": item.created_at,
        } for item in db.scalars(select(User).where(User.id.in_(select(Membership.user_id).where(
            Membership.household_id == budget.household_id
        ))))],
        "accounts": [row_data(item) for item in db.scalars(select(Account).where(Account.budget_id == budget_id))],
        "category_groups": [row_data(item) for item in db.scalars(select(CategoryGroup).where(CategoryGroup.budget_id == budget_id))],
        "categories": [row_data(item) for item in db.scalars(select(Category).where(Category.budget_id == budget_id))],
        "targets": [row_data(item) for item in db.scalars(select(CategoryTarget).where(CategoryTarget.budget_id == budget_id))],
        "scheduled_transactions": [row_data(item) for item in db.scalars(select(ScheduledTransaction).where(ScheduledTransaction.budget_id == budget_id))],
        "transactions": [row_data(item) for item in transactions],
        "transaction_splits": [row_data(item) for item in db.scalars(select(TransactionSplit).where(
            TransactionSplit.transaction_id.in_(transaction_ids)
        ))] if transaction_ids else [],
        "allocation_operations": [row_data(item) for item in operations],
        "allocation_postings": [row_data(item) for item in db.scalars(select(AllocationPosting).where(
            AllocationPosting.operation_id.in_(operation_ids)
        ))] if operation_ids else [],
        "credit_card_reserve_events": [row_data(item) for item in db.scalars(select(CreditCardReserveEvent).where(
            CreditCardReserveEvent.budget_id == budget_id
        ))],
        "requests": [row_data(item) for item in requests],
        "request_actions": [row_data(item) for item in db.scalars(select(RequestAction).where(
            RequestAction.request_id.in_(request_ids)
        ))] if request_ids else [],
        "allowance_plans": [row_data(item) for item in plans],
        "allowance_splits": [row_data(item) for item in db.scalars(select(AllowanceSplit).where(
            AllowanceSplit.plan_id.in_(plan_ids)
        ))] if plan_ids else [],
        "allowance_issuances": [row_data(item) for item in db.scalars(select(AllowanceIssuance).where(
            AllowanceIssuance.budget_id == budget_id
        ))],
        "legacy_monthly_assignments": [row_data(item) for item in db.scalars(select(MonthlyAssignment).where(
            MonthlyAssignment.budget_id == budget_id
        ))],
        "access_profiles": [row_data(item) for item in db.scalars(select(BudgetAccessProfile).where(
            BudgetAccessProfile.budget_id == budget_id
        ))],
        "capability_grants": [row_data(item) for item in db.scalars(select(CapabilityGrant).where(
            CapabilityGrant.budget_id == budget_id
        ))],
        "resource_grants": [row_data(item) for item in db.scalars(select(ResourceGrant).where(
            ResourceGrant.budget_id == budget_id
        ))],
    }
    return jsonable_encoder(payload)
