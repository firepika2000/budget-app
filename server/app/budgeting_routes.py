from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from .access import find_visible_budget, has_budget_permission
from .database import get_db
from .dependencies import get_current_user
from .models import (
    Account,
    Budget,
    BudgetPermission,
    Category,
    CategoryGroup,
    MonthlyAssignment,
    Transaction,
    User,
)
from .schemas import (
    AccountCreate,
    AccountResponse,
    AssignmentResponse,
    AssignmentUpsert,
    CategoryCreate,
    CategoryGroupCreate,
    CategoryGroupResponse,
    CategoryResponse,
    TransactionCreate,
    TransactionResponse,
)


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


def require_budget(
    db: Session,
    user: User,
    budget_id: str,
    permission: BudgetPermission,
) -> Budget:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    if not has_budget_permission(db, user, budget, permission):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permission")
    return budget


@router.get("/accounts", response_model=list[AccountResponse])
def list_accounts(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Account]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Account).where(Account.budget_id == budget_id).order_by(Account.name)))


@router.post("/accounts", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(
    budget_id: str,
    body: AccountCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    account = Account(budget_id=budget_id, **body.model_dump())
    db.add(account)
    db.commit()
    db.refresh(account)
    return account


@router.get("/category-groups", response_model=list[CategoryGroupResponse])
def list_category_groups(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[CategoryGroup]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(CategoryGroup).where(
        CategoryGroup.budget_id == budget_id
    ).order_by(CategoryGroup.sort_order, CategoryGroup.name)))


@router.post("/category-groups", response_model=CategoryGroupResponse, status_code=status.HTTP_201_CREATED)
def create_category_group(
    budget_id: str,
    body: CategoryGroupCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CategoryGroup:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    group = CategoryGroup(budget_id=budget_id, **body.model_dump())
    db.add(group)
    db.commit()
    db.refresh(group)
    return group


@router.get("/categories", response_model=list[CategoryResponse])
def list_categories(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Category]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Category).where(
        Category.budget_id == budget_id
    ).order_by(Category.group_id, Category.sort_order, Category.name)))


@router.post("/categories", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
def create_category(
    budget_id: str,
    body: CategoryCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Category:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    group = db.get(CategoryGroup, body.group_id)
    if group is None or group.budget_id != budget_id:
        raise HTTPException(status_code=422, detail="Invalid category group")
    category = Category(budget_id=budget_id, **body.model_dump())
    db.add(category)
    db.commit()
    db.refresh(category)
    return category


@router.put("/categories/{category_id}/assignment", response_model=AssignmentResponse)
def upsert_assignment(
    budget_id: str,
    category_id: str,
    body: AssignmentUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MonthlyAssignment:
    require_budget(db, user, budget_id, BudgetPermission.MANAGE)
    category = db.get(Category, category_id)
    if category is None or category.budget_id != budget_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Category not found")
    assignment = db.scalar(select(MonthlyAssignment).where(
        MonthlyAssignment.category_id == category_id,
        MonthlyAssignment.month == body.month,
    ))
    if assignment is None:
        assignment = MonthlyAssignment(
            budget_id=budget_id,
            category_id=category_id,
            month=body.month,
            assigned_minor=body.assigned_minor,
        )
        db.add(assignment)
    else:
        assignment.assigned_minor = body.assigned_minor
    db.commit()
    db.refresh(assignment)
    return assignment


@router.get("/transactions", response_model=list[TransactionResponse])
def list_transactions(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Transaction]:
    require_budget(db, user, budget_id, BudgetPermission.VIEW)
    return list(db.scalars(select(Transaction).where(
        Transaction.budget_id == budget_id
    ).order_by(Transaction.occurred_on.desc(), Transaction.created_at.desc())))


@router.post("/transactions", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def create_transaction(
    budget_id: str,
    body: TransactionCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Transaction:
    require_budget(db, user, budget_id, BudgetPermission.CONTRIBUTE)
    account = db.get(Account, body.account_id)
    if account is None or account.budget_id != budget_id or account.is_closed:
        raise HTTPException(status_code=422, detail="Invalid account")
    if body.category_id is not None:
        category = db.get(Category, body.category_id)
        if category is None or category.budget_id != budget_id or category.is_archived:
            raise HTTPException(status_code=422, detail="Invalid category")
    transaction = Transaction(
        budget_id=budget_id,
        created_by_user_id=user.id,
        **body.model_dump(),
    )
    db.add(transaction)
    db.commit()
    db.refresh(transaction)
    return transaction
