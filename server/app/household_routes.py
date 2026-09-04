from datetime import datetime, timedelta, timezone
from hashlib import sha256
import secrets

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .access import is_household_owner
from .config import Settings
from .database import get_db
from .dependencies import get_current_user, get_settings
from .models import Budget, BudgetGrant, Household, Invitation, Membership, User
from .schemas import (
    InvitationAccept,
    InvitationCreate,
    InvitationResponse,
    MeResponse,
    MemberResponse,
    TokenResponse,
)
from .security import create_access_token, hash_password, verify_password


router = APIRouter(prefix="/api/v1")


def token_hash(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()


@router.get("/me", response_model=MeResponse)
def me(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    memberships = list(db.scalars(select(Membership).where(Membership.user_id == user.id)))
    households = {item.id: item for item in db.scalars(select(Household).where(
        Household.id.in_([membership.household_id for membership in memberships])
    ))} if memberships else {}
    return {
        "id": user.id,
        "email": user.email,
        "display_name": user.display_name,
        "households": [
            {
                "id": membership.household_id,
                "name": households[membership.household_id].name,
                "role": membership.role,
                "is_active": membership.is_active,
            }
            for membership in memberships
        ],
    }


@router.post(
    "/households/{household_id}/invitations",
    response_model=InvitationResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_invitation(
    household_id: str,
    body: InvitationCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Household not found")
    existing_user = db.scalar(select(User).where(User.email == body.email))
    if existing_user is not None:
        existing_membership = db.scalar(select(Membership).where(
            Membership.household_id == household_id,
            Membership.user_id == existing_user.id,
        ))
        if existing_membership is not None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User is already a household member")
    raw_token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + timedelta(days=7)
    invitation = Invitation(
        household_id=household_id,
        email=body.email,
        role=body.role,
        token_hash=token_hash(raw_token),
        expires_at=expires_at,
        created_by_user_id=user.id,
    )
    db.add(invitation)
    db.commit()
    return {
        "invitation_token": raw_token,
        "email": invitation.email,
        "role": invitation.role,
        "expires_at": expires_at.isoformat(),
    }


@router.post("/auth/accept-invitation", response_model=TokenResponse)
def accept_invitation(
    body: InvitationAccept,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    invitation = db.scalar(select(Invitation).where(
        Invitation.token_hash == token_hash(body.invitation_token)
    ))
    now = datetime.now(timezone.utc)
    if invitation is None or invitation.accepted_at is not None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invitation is invalid")
    expires_at = invitation.expires_at
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    if expires_at <= now:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invitation has expired")

    user = db.scalar(select(User).where(User.email == invitation.email))
    if user is None:
        user = User(
            email=invitation.email,
            display_name=body.display_name.strip(),
            password_hash=hash_password(body.password),
        )
        db.add(user)
        db.flush()
    elif not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Existing account password is incorrect")

    db.add(Membership(
        household_id=invitation.household_id,
        user_id=user.id,
        role=invitation.role,
    ))
    invitation.accepted_at = now
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User is already a household member")
    return TokenResponse(access_token=create_access_token(user.id, settings))


@router.get("/households/{household_id}/members", response_model=list[MemberResponse])
def list_members(
    household_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Household not found")
    rows = db.execute(
        select(Membership, User)
        .join(User, User.id == Membership.user_id)
        .where(Membership.household_id == household_id)
        .order_by(User.display_name, User.id)
    ).all()
    return [{
        "user_id": member.user_id,
        "email": member_user.email,
        "display_name": member_user.display_name,
        "role": member.role,
        "is_active": member.is_active,
    } for member, member_user in rows]


@router.delete("/households/{household_id}/members/{member_user_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_member(
    household_id: str,
    member_user_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Household not found")
    if member_user_id == user.id:
        raise HTTPException(status_code=422, detail="Owner cannot deactivate self")
    membership = db.scalar(select(Membership).where(
        Membership.household_id == household_id,
        Membership.user_id == member_user_id,
        Membership.is_active.is_(True),
    ))
    if membership is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Member not found")
    membership.is_active = False
    membership.authorization_version += 1
    budget_ids = select(Budget.id).where(Budget.household_id == household_id)
    db.execute(delete(BudgetGrant).where(
        BudgetGrant.user_id == member_user_id,
        BudgetGrant.budget_id.in_(budget_ids),
    ))
    db.commit()
