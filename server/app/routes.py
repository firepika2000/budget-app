from typing import Optional
from datetime import date, datetime, timedelta, timezone
from hashlib import sha256
import ipaddress
import secrets
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import delete, select, update
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
    CashRolloverPolicyChange,
    BudgetAccessProfile,
    BudgetGrant,
    CapabilityGrant,
    Category,
    ImportBatch,
    Household,
    HouseholdAccessEvent,
    HouseholdRole,
    Membership,
    ResourceGrant,
    SetupState,
    PairingCode,
    RefreshSession,
    TransactionAttachment,
    User,
    now_utc,
)
from .schemas import (
    AccessProfileResponse,
    AccessProfileUpsert,
    BootstrapRequest,
    BootstrapStatusResponse,
    BudgetCreate,
    BudgetDeleteConfirmation,
    BudgetResponse,
    GrantResponse,
    GrantUpsert,
    LoginRequest,
    DeviceSessionResponse,
    PairingCodeResponse,
    PairingRedeemRequest,
    RefreshRequest,
    TokenResponse,
)
from .security import hash_password, verify_password
from .sessions import issue_session, revoke_session, rotate_session
from .starter_plan import install_starter_plan
from .attachment_storage import AttachmentStorage


router = APIRouter(prefix="/api/v1")

# Single source for the client compatibility check; keep in step with the FastAPI app version.
API_VERSION = "0.4.0"


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/bootstrap/status", response_model=BootstrapStatusResponse)
def bootstrap_status(db: Session = Depends(get_db)) -> BootstrapStatusResponse:
    """Let the client discover whether first-run setup or sign-in is required, without
    inferring it from authentication failures and without leaking any household data."""
    initialized = (
        db.scalar(select(SetupState.id).limit(1)) is not None
        or db.scalar(select(User.id).limit(1)) is not None
    )
    return BootstrapStatusResponse(
        initialized=initialized,
        authentication_required=True,
        api_version=API_VERSION,
    )


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
    return issue_session(db, user, settings, body.device_name)


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


def _is_loopback(host: Optional[str]) -> bool:
    if host is None:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _require_secure_pairing_request(request: Request) -> None:
    if request.url.scheme.lower() != "https" and not _is_loopback(request.url.hostname):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Device pairing requires HTTPS")


def _pairing_public_url(settings: Settings) -> str:
    raw = (settings.pairing_public_url or "").strip().rstrip("/")
    parsed = urlsplit(raw)
    if (
        not raw or parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname
        or parsed.username is not None or parsed.password is not None
        or parsed.query or parsed.fragment or parsed.path not in {"", "/"}
        or (parsed.scheme.lower() != "https" and not _is_loopback(parsed.hostname))
    ):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Secure device pairing is not configured",
        )
    return raw


@router.post("/auth/pairing-code", response_model=PairingCodeResponse, status_code=status.HTTP_201_CREATED)
def create_pairing_code(
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> PairingCodeResponse:
    _require_secure_pairing_request(request)
    public_url = _pairing_public_url(settings)
    now = datetime.now(timezone.utc)
    # One active code per user limits accidental screenshots and makes regeneration revoke the old QR.
    db.execute(delete(PairingCode).where(
        (PairingCode.user_id == user.id) | (PairingCode.expires_at <= now)
    ))
    raw_code = secrets.token_urlsafe(48)
    pairing = PairingCode(
        user_id=user.id,
        token_hash=sha256(raw_code.encode("utf-8")).hexdigest(),
        expires_at=now + timedelta(minutes=settings.pairing_code_minutes),
    )
    db.add(pairing)
    db.commit()
    return PairingCodeResponse(code=raw_code, server_url=public_url, expires_at=pairing.expires_at)


@router.post("/auth/pair", response_model=TokenResponse)
def redeem_pairing_code(
    body: PairingRedeemRequest,
    request: Request,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    _require_secure_pairing_request(request)
    _pairing_public_url(settings)
    rate_limiter = request.app.state.auth_rate_limiter
    rate_key = rate_limiter.key(request, "device-pairing")
    rate_limiter.check(rate_key)
    token_hash = sha256(body.code.encode("utf-8")).hexdigest()
    pairing = db.scalar(select(PairingCode).where(PairingCode.token_hash == token_hash))
    now = datetime.now(timezone.utc)
    invalid = pairing is None or pairing.redeemed_at is not None
    if pairing is not None:
        expires_at = pairing.expires_at
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        invalid = invalid or expires_at <= now
    if invalid:
        rate_limiter.failed(rate_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired pairing code")
    claimed = db.execute(update(PairingCode).where(
        PairingCode.id == pairing.id,
        PairingCode.redeemed_at.is_(None),
        PairingCode.expires_at > now,
    ).values(redeemed_at=now).execution_options(synchronize_session=False))
    if claimed.rowcount != 1:
        db.rollback()
        rate_limiter.failed(rate_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired pairing code")
    user = db.get(User, pairing.user_id)
    if user is None:
        db.rollback()
        rate_limiter.failed(rate_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired pairing code")
    db.delete(pairing)
    rate_limiter.succeeded(rate_key)
    return issue_session(db, user, settings, body.device_name)


@router.get("/auth/sessions", response_model=list[DeviceSessionResponse])
def list_device_sessions(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[DeviceSessionResponse]:
    now = datetime.now(timezone.utc)
    sessions = list(db.scalars(select(RefreshSession).where(
        RefreshSession.user_id == user.id,
        RefreshSession.revoked_at.is_(None),
        RefreshSession.expires_at > now,
    ).order_by(RefreshSession.created_at.desc(), RefreshSession.id)))
    return [DeviceSessionResponse(
        id=item.id,
        device_name=item.device_name or "Signed-in device",
        created_at=item.created_at,
        expires_at=item.expires_at,
    ) for item in sessions]


@router.delete("/auth/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def revoke_device_session(
    session_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    device_session = db.scalar(select(RefreshSession).where(
        RefreshSession.id == session_id,
        RefreshSession.user_id == user.id,
    ))
    if device_session is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device session not found")
    if device_session.revoked_at is None:
        device_session.revoked_at = datetime.now(timezone.utc)
        db.commit()


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
    db.flush()
    if body.starter_template:
        install_starter_plan(db, budget.id)
    if body.cash_rollover_policy is not None:
        db.add(CashRolloverPolicyChange(
            budget_id=budget.id, effective_month=date.min, policy=body.cash_rollover_policy,
            version=0, source="budget_creation", actor_user_id=user.id,
        ))
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


@router.delete("/budgets/{budget_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_budget(
    request: Request,
    budget_id: str,
    body: BudgetDeleteConfirmation,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    budget = db.get(Budget, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Budget not found")
    if not secrets.compare_digest(body.confirmation_name, budget.name):
        raise HTTPException(status_code=422, detail="Type the exact budget name to confirm deletion")

    settings = request.app.state.settings
    storage = AttachmentStorage(
        settings.attachment_storage_path,
        settings.jwt_secret,
        settings.attachment_encryption_key,
    )
    storage_keys = list(db.scalars(select(TransactionAttachment.storage_key).where(
        TransactionAttachment.budget_id == budget_id
    )))
    quarantine = storage.quarantine(storage_keys, secrets.token_hex(16))
    try:
        # Import review rows deliberately use RESTRICT so normal ledger deletion cannot erase a
        # pending import. Whole-budget deletion is the explicit exception and removes them first.
        db.execute(delete(ImportBatch).where(ImportBatch.budget_id == budget_id))
        # Break the account/payment-category cycle before the database cascades all budget rows.
        db.execute(update(Account).where(Account.budget_id == budget_id).values(payment_category_id=None))
        db.delete(budget)
        db.commit()
    except Exception:
        db.rollback()
        storage.restore_quarantine(quarantine)
        raise
    storage.purge_quarantine(quarantine)


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
    if member is None or member.role == "owner":
        raise HTTPException(status_code=422, detail="User is not an active non-owner household member")
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
    db.add(HouseholdAccessEvent(household_id=budget.household_id, actor_user_id=user.id,
                                subject_user_id=body.user_id, event_type="budget_grant_updated",
                                detail=f"{budget.name}: {body.permission}"))
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
    db.add(HouseholdAccessEvent(household_id=budget.household_id, actor_user_id=user.id,
                                subject_user_id=member_user_id, event_type="budget_grant_revoked",
                                detail=budget.name))
    db.commit()


def access_profile_response(
    db: Session,
    budget: Budget,
    member: Membership,
    profile: Optional[BudgetAccessProfile],
) -> AccessProfileResponse:
    member_user = db.get(User, member.user_id)
    grant = db.scalar(select(BudgetGrant).where(
        BudgetGrant.budget_id == budget.id,
        BudgetGrant.user_id == member.user_id,
    ))
    if grant is None:
        raise HTTPException(status_code=422, detail="User needs a budget grant before scoped access")
    capabilities = (
        list(db.scalars(select(CapabilityGrant.capability).where(
            CapabilityGrant.budget_id == budget.id,
            CapabilityGrant.user_id == member.user_id,
        )))
        if profile is not None
        else sorted(effective_capabilities(db, member_user, budget))
    )
    resources = list(db.execute(select(ResourceGrant.resource_type, ResourceGrant.resource_id).where(
        ResourceGrant.budget_id == budget.id,
        ResourceGrant.user_id == member.user_id,
    )).all()) if profile is not None else []
    updater = db.get(User, profile.updated_by_user_id) if profile is not None else None
    version = int(profile.updated_at.timestamp() * 1_000_000) if profile is not None else 0
    return AccessProfileResponse(
        budget_id=budget.id,
        user_id=member.user_id,
        capabilities=sorted(capabilities),
        restrict_accounts=profile.restrict_accounts if profile is not None else False,
        account_ids=sorted(resource_id for resource_type, resource_id in resources if resource_type == "account"),
        restrict_categories=profile.restrict_categories if profile is not None else False,
        category_ids=sorted(resource_id for resource_type, resource_id in resources if resource_type == "category"),
        expected_version=None,
        grant_permission=grant.permission,
        is_custom=profile is not None,
        version=version,
        updated_by_user_id=profile.updated_by_user_id if profile is not None else None,
        updated_by_display_name=updater.display_name if updater is not None else None,
        updated_at=profile.updated_at if profile is not None else None,
    )


@router.get(
    "/budgets/{budget_id}/access/{member_user_id}",
    response_model=AccessProfileResponse,
)
def get_access_profile(
    budget_id: str,
    member_user_id: str,
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
    if member is None or member.role == "owner":
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Member not found")
    profile = db.scalar(select(BudgetAccessProfile).where(
        BudgetAccessProfile.budget_id == budget_id,
        BudgetAccessProfile.user_id == member_user_id,
    ))
    return access_profile_response(db, budget, member, profile)


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
    if member is None or member.role == "owner":
        raise HTTPException(status_code=422, detail="User is not an active non-owner household member")
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
    ).with_for_update())
    current_version = int(profile.updated_at.timestamp() * 1_000_000) if profile is not None else 0
    if body.expected_version is not None and body.expected_version != current_version:
        raise HTTPException(status_code=409, detail="Access changed since it was loaded. Refresh and try again.")
    if profile is None:
        profile = BudgetAccessProfile(
            budget_id=budget_id,
            user_id=member_user_id,
            updated_by_user_id=user.id,
        )
        db.add(profile)
        try:
            db.flush()
        except IntegrityError:
            db.rollback()
            raise HTTPException(status_code=409, detail="Access changed since it was loaded. Refresh and try again.")
    profile.restrict_accounts = body.restrict_accounts
    profile.restrict_categories = body.restrict_categories
    profile.updated_by_user_id = user.id
    profile.updated_at = now_utc()
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
    db.add(HouseholdAccessEvent(household_id=budget.household_id, actor_user_id=user.id,
                                subject_user_id=member_user_id, event_type="access_profile_updated",
                                detail=budget.name))
    db.commit()
    db.refresh(profile)
    return access_profile_response(db, budget, member, profile)
