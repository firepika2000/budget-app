from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .access import (
    effective_capabilities,
    effective_budget_permission,
    find_visible_budget,
    is_household_owner,
    visible_budgets_query,
)
from .config import Settings
from .database import get_db
from .dependencies import get_current_user, get_settings
from .models import (
    Account,
    Budget,
    BudgetAccessProfile,
    BudgetGrant,
    CapabilityGrant,
    Category,
    Household,
    HouseholdRole,
    Membership,
    ResourceGrant,
    SetupState,
    User,
)
from .schemas import (
    AccessProfileResponse,
    AccessProfileUpsert,
    BootstrapRequest,
    BudgetCreate,
    BudgetResponse,
    GrantResponse,
    GrantUpsert,
    LoginRequest,
    RefreshRequest,
    TokenResponse,
)
from .security import hash_password, verify_password
from .sessions import issue_session, revoke_session, rotate_session


router = APIRouter(prefix="/api/v1")


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.post("/auth/bootstrap", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def bootstrap(
    body: BootstrapRequest,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    try:
        db.add(SetupState(id=1))
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Server is already configured")

    user = User(
        email=body.email,
        display_name=body.display_name.strip(),
        password_hash=hash_password(body.password),
    )
    db.add(user)
    db.flush()
    household = Household(name=body.household_name.strip(), owner_user_id=user.id)
    db.add(household)
    db.flush()
    db.add(Membership(
        household_id=household.id,
        user_id=user.id,
        role=HouseholdRole.OWNER.value,
    ))
    return issue_session(db, user, settings)


@router.post("/auth/login", response_model=TokenResponse)
def login(
    body: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    rate_limiter = request.app.state.auth_rate_limiter
    rate_key = rate_limiter.key(request, body.email)
    rate_limiter.check(rate_key)
    user = db.scalar(select(User).where(User.email == body.email.strip().lower()))
    if user is None or not verify_password(body.password, user.password_hash):
        rate_limiter.failed(rate_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password")
    rate_limiter.succeeded(rate_key)
    return issue_session(db, user, settings)


@router.post("/auth/refresh", response_model=TokenResponse)
def refresh(
    body: RefreshRequest,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    return rotate_session(db, body.refresh_token, settings)


@router.post("/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(body: RefreshRequest, db: Session = Depends(get_db)) -> None:
    revoke_session(db, body.refresh_token)


@router.get("/budgets", response_model=list[BudgetResponse])
def list_budgets(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    budgets = list(db.scalars(visible_budgets_query(user).order_by(Budget.name, Budget.id)))
    return [budget_response(db, user, budget) for budget in budgets]


@router.post("/budgets", response_model=BudgetResponse, status_code=status.HTTP_201_CREATED)
def create_budget(
    body: BudgetCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if not is_household_owner(db, user, body.household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    budget = Budget(
        household_id=body.household_id,
        name=body.name.strip(),
        currency_code=body.currency_code,
    )
    db.add(budget)
    db.commit()
    db.refresh(budget)
    return budget_response(db, user, budget)


@router.get("/budgets/{budget_id}", response_model=BudgetResponse)
def get_budget(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    return budget_response(db, user, budget)


def budget_response(db: Session, user: User, budget: Budget) -> dict:
    permission = effective_budget_permission(db, user, budget)
    if permission is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    return {
        "id": budget.id,
        "household_id": budget.household_id,
        "name": budget.name,
        "currency_code": budget.currency_code,
        "effective_permission": permission,
        "allocation_version": budget.allocation_version,
        "capabilities": sorted(effective_capabilities(db, user, budget)),
    }


@router.put("/budgets/{budget_id}/grants", response_model=GrantResponse)
def upsert_grant(
    budget_id: str,
    body: GrantUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BudgetGrant:
    budget = db.get(Budget, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    member = db.scalar(select(Membership).where(
        Membership.household_id == budget.household_id,
        Membership.user_id == body.user_id,
        Membership.is_active.is_(True),
    ))
    if member is None:
        raise HTTPException(status_code=422, detail="User is not an active household member")
    grant = db.scalar(select(BudgetGrant).where(
        BudgetGrant.budget_id == budget.id,
        BudgetGrant.user_id == body.user_id,
    ))
    if grant is None:
        grant = BudgetGrant(
            budget_id=budget.id,
            user_id=body.user_id,
            permission=body.permission,
        )
        db.add(grant)
    else:
        grant.permission = body.permission
    db.commit()
    db.refresh(grant)
    return grant


@router.delete(
    "/budgets/{budget_id}/grants/{member_user_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def revoke_grant(
    budget_id: str,
    member_user_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = db.get(Budget, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    result = db.execute(delete(BudgetGrant).where(
        BudgetGrant.budget_id == budget_id,
        BudgetGrant.user_id == member_user_id,
    ))
    if result.rowcount == 0:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Grant not found")
    db.execute(delete(CapabilityGrant).where(
        CapabilityGrant.budget_id == budget_id,
        CapabilityGrant.user_id == member_user_id,
    ))
    db.execute(delete(ResourceGrant).where(
        ResourceGrant.budget_id == budget_id,
        ResourceGrant.user_id == member_user_id,
    ))
    db.execute(delete(BudgetAccessProfile).where(
        BudgetAccessProfile.budget_id == budget_id,
        BudgetAccessProfile.user_id == member_user_id,
    ))
    db.commit()


@router.put(
    "/budgets/{budget_id}/access/{member_user_id}",
    response_model=AccessProfileResponse,
)
def configure_access_profile(
    budget_id: str,
    member_user_id: str,
    body: AccessProfileUpsert,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AccessProfileResponse:
    budget = db.get(Budget, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    member = db.scalar(select(Membership).where(
        Membership.household_id == budget.household_id,
        Membership.user_id == member_user_id,
        Membership.is_active.is_(True),
    ))
    if member is None:
        raise HTTPException(status_code=422, detail="User is not an active household member")
    if not db.scalar(select(BudgetGrant.id).where(
        BudgetGrant.budget_id == budget_id,
        BudgetGrant.user_id == member_user_id,
    )):
        raise HTTPException(status_code=422, detail="User needs a budget grant before scoped access")
    valid_accounts = set(db.scalars(select(Account.id).where(
        Account.budget_id == budget_id,
        Account.id.in_(body.account_ids),
    ))) if body.account_ids else set()
    valid_categories = set(db.scalars(select(Category.id).where(
        Category.budget_id == budget_id,
        Category.id.in_(body.category_ids),
    ))) if body.category_ids else set()
    if valid_accounts != set(body.account_ids) or valid_categories != set(body.category_ids):
        raise HTTPException(status_code=422, detail="Scoped resources must belong to the budget")

    profile = db.scalar(select(BudgetAccessProfile).where(
        BudgetAccessProfile.budget_id == budget_id,
        BudgetAccessProfile.user_id == member_user_id,
    ))
    if profile is None:
        profile = BudgetAccessProfile(
            budget_id=budget_id,
            user_id=member_user_id,
            updated_by_user_id=user.id,
        )
        db.add(profile)
    profile.restrict_accounts = body.restrict_accounts
    profile.restrict_categories = body.restrict_categories
    profile.updated_by_user_id = user.id
    db.execute(delete(CapabilityGrant).where(
        CapabilityGrant.budget_id == budget_id,
        CapabilityGrant.user_id == member_user_id,
    ))
    db.execute(delete(ResourceGrant).where(
        ResourceGrant.budget_id == budget_id,
        ResourceGrant.user_id == member_user_id,
    ))
    db.add_all([
        CapabilityGrant(budget_id=budget_id, user_id=member_user_id, capability=capability)
        for capability in body.capabilities
    ])
    db.add_all([
        ResourceGrant(
            budget_id=budget_id,
            user_id=member_user_id,
            resource_type=resource_type,
            resource_id=resource_id,
        )
        for resource_type, ids in (("account", body.account_ids), ("category", body.category_ids))
        for resource_id in ids
    ])
    db.commit()
    return AccessProfileResponse(
        budget_id=budget_id,
        user_id=member_user_id,
        **body.model_dump(),
    )
