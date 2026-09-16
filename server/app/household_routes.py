from datetime import datetime, timedelta, timezone
from hashlib import sha256
import secrets
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .access import is_household_owner
from .config import Settings
from .database import get_db
from .dependencies import get_current_user, get_settings
from .models import (
    Budget,
    BudgetAccessProfile,
    BudgetGrant,
    CapabilityGrant,
    Household,
    HouseholdAccessEvent,
    Invitation,
    Membership,
    ResourceGrant,
    User,
)
from .schemas import (
    InvitationAccept,
    InvitationCreate,
    InvitationResponse,
    InvitationSummary,
    HouseholdAccessEventResponse,
    MeResponse,
    MemberResponse,
    TokenResponse,
)
from .security import hash_password, verify_password
from .sessions import issue_session


router = APIRouter(prefix="/api/v1")


def token_hash(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()


def record_access_event(
    db: Session,
    *,
    household_id: str,
    actor_user_id: str,
    event_type: str,
    subject_user_id: Optional[str] = None,
    invitation_id: Optional[str] = None,
    detail: Optional[str] = None,
) -> None:
    db.add(HouseholdAccessEvent(
        household_id=household_id,
        actor_user_id=actor_user_id,
        subject_user_id=subject_user_id,
        invitation_id=invitation_id,
        event_type=event_type,
        detail=detail,
    ))


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
        if existing_membership is not None and existing_membership.is_active:
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
    db.flush()
    record_access_event(
        db,
        household_id=household_id,
        actor_user_id=user.id,
        invitation_id=invitation.id,
        event_type="invitation_created",
        detail=invitation.email,
    )
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
    if invitation is None or invitation.accepted_at is not None or invitation.canceled_at is not None:
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

    membership = db.scalar(select(Membership).where(
        Membership.household_id == invitation.household_id,
        Membership.user_id == user.id,
    ))
    if membership is None:
        db.add(Membership(household_id=invitation.household_id, user_id=user.id, role=invitation.role))
    elif membership.is_active:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User is already a household member")
    else:
        membership.is_active = True
        membership.role = invitation.role
        membership.authorization_version += 1
    invitation.accepted_at = now
    record_access_event(
        db,
        household_id=invitation.household_id,
        actor_user_id=user.id,
        subject_user_id=user.id,
        invitation_id=invitation.id,
        event_type="invitation_accepted",
        detail=invitation.email,
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User is already a household member")
    return issue_session(db, user, settings)


@router.get("/households/{household_id}/invitations", response_model=list[InvitationSummary])
def list_invitations(
    household_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=404, detail="Household not found")
    now = datetime.now(timezone.utc)
    creators = {item.id: item.display_name for item in db.scalars(select(User))}
    rows = list(db.scalars(select(Invitation).where(
        Invitation.household_id == household_id
    ).order_by(Invitation.created_at.desc(), Invitation.id.desc())))
    result = []
    for invitation in rows:
        expires_at = invitation.expires_at
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        state = "accepted" if invitation.accepted_at else "canceled" if invitation.canceled_at else "expired" if expires_at <= now else "pending"
        result.append({
            "id": invitation.id,
            "email": invitation.email,
            "role": invitation.role,
            "status": state,
            "expires_at": expires_at.isoformat(),
            "created_at": invitation.created_at.isoformat(),
            "created_by_display_name": creators.get(invitation.created_by_user_id, "Former member"),
        })
    return result


@router.delete("/households/{household_id}/invitations/{invitation_id}", status_code=204)
def cancel_invitation(
    household_id: str,
    invitation_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=404, detail="Household not found")
    invitation = db.scalar(select(Invitation).where(
        Invitation.id == invitation_id, Invitation.household_id == household_id
    ).with_for_update())
    if invitation is None:
        raise HTTPException(status_code=404, detail="Invitation not found")
    if invitation.accepted_at is not None:
        raise HTTPException(status_code=409, detail="Accepted invitations cannot be canceled")
    if invitation.canceled_at is None:
        invitation.canceled_at = datetime.now(timezone.utc)
        record_access_event(db, household_id=household_id, actor_user_id=user.id,
                            invitation_id=invitation.id, event_type="invitation_canceled", detail=invitation.email)
        db.commit()


@router.post("/households/{household_id}/invitations/{invitation_id}/resend", response_model=InvitationResponse)
def resend_invitation(
    household_id: str,
    invitation_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=404, detail="Household not found")
    previous = db.scalar(select(Invitation).where(
        Invitation.id == invitation_id, Invitation.household_id == household_id
    ).with_for_update())
    if previous is None:
        raise HTTPException(status_code=404, detail="Invitation not found")
    if previous.accepted_at is not None:
        raise HTTPException(status_code=409, detail="Accepted invitations cannot be resent")
    previous.canceled_at = datetime.now(timezone.utc)
    raw_token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + timedelta(days=7)
    replacement = Invitation(household_id=household_id, email=previous.email, role=previous.role,
                             token_hash=token_hash(raw_token), expires_at=expires_at, created_by_user_id=user.id)
    db.add(replacement)
    db.flush()
    record_access_event(db, household_id=household_id, actor_user_id=user.id,
                        invitation_id=replacement.id, event_type="invitation_resent", detail=replacement.email)
    db.commit()
    return {"invitation_token": raw_token, "email": replacement.email, "role": replacement.role,
            "expires_at": expires_at.isoformat()}


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
        "authorization_version": member.authorization_version,
    } for member, member_user in rows]


@router.get("/households/{household_id}/access-events", response_model=list[HouseholdAccessEventResponse])
def list_access_events(
    household_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=404, detail="Household not found")
    users = {item.id: item.display_name for item in db.scalars(select(User))}
    rows = list(db.scalars(select(HouseholdAccessEvent).where(
        HouseholdAccessEvent.household_id == household_id
    ).order_by(HouseholdAccessEvent.created_at.desc(), HouseholdAccessEvent.id.desc()).limit(200)))
    return [{"id": row.id, "event_type": row.event_type,
             "actor_display_name": users.get(row.actor_user_id, "Former member"),
             "subject_display_name": users.get(row.subject_user_id) if row.subject_user_id else None,
             "detail": row.detail, "created_at": row.created_at.isoformat()} for row in rows]


def deactivate_membership(db: Session, household_id: str, member_user_id: str, actor: User) -> None:
    household = db.scalar(select(Household).where(Household.id == household_id).with_for_update())
    if household is None:
        raise HTTPException(status_code=404, detail="Household not found")
    if member_user_id == household.owner_user_id:
        raise HTTPException(status_code=422, detail="Household owner cannot leave or be removed")
    membership = db.scalar(select(Membership).where(
        Membership.household_id == household_id,
        Membership.user_id == member_user_id,
        Membership.is_active.is_(True),
    ).with_for_update())
    if membership is None:
        raise HTTPException(status_code=404, detail="Member not found")
    membership.is_active = False
    membership.authorization_version += 1
    record_access_event(db, household_id=household_id, actor_user_id=actor.id,
                        subject_user_id=member_user_id,
                        event_type="member_left" if actor.id == member_user_id else "member_removed")
    db.commit()


@router.delete("/households/{household_id}/members/me", status_code=204)
def leave_household(
    household_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    deactivate_membership(db, household_id, user.id, user)


@router.delete("/households/{household_id}/members/{member_user_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_member(
    household_id: str,
    member_user_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    if not is_household_owner(db, user, household_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Household not found")
    deactivate_membership(db, household_id, member_user_id, user)
