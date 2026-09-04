from datetime import datetime, timedelta, timezone
from hashlib import sha256
import secrets

from fastapi import HTTPException, status
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from .config import Settings
from .models import RefreshSession, User
from .schemas import TokenResponse
from .security import create_access_token


def refresh_token_hash(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()


def issue_session(db: Session, user: User, settings: Settings) -> TokenResponse:
    raw_refresh_token = secrets.token_urlsafe(48)
    db.add(RefreshSession(
        user_id=user.id,
        token_hash=refresh_token_hash(raw_refresh_token),
        expires_at=datetime.now(timezone.utc) + timedelta(days=settings.refresh_token_days),
    ))
    db.commit()
    return TokenResponse(
        access_token=create_access_token(user.id, settings),
        refresh_token=raw_refresh_token,
    )


def rotate_session(db: Session, raw_token: str, settings: Settings) -> TokenResponse:
    session = db.scalar(select(RefreshSession).where(
        RefreshSession.token_hash == refresh_token_hash(raw_token)
    ))
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired refresh token",
    )
    if session is None:
        raise unauthorized
    now = datetime.now(timezone.utc)
    expires_at = session.expires_at
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    if session.revoked_at is not None:
        db.execute(update(RefreshSession).where(
            RefreshSession.user_id == session.user_id,
            RefreshSession.revoked_at.is_(None),
        ).values(revoked_at=now))
        db.commit()
        raise unauthorized
    if expires_at <= now:
        session.revoked_at = now
        db.commit()
        raise unauthorized
    user = db.get(User, session.user_id)
    if user is None:
        raise unauthorized
    session.revoked_at = now
    return issue_session(db, user, settings)


def revoke_session(db: Session, raw_token: str) -> None:
    session = db.scalar(select(RefreshSession).where(
        RefreshSession.token_hash == refresh_token_hash(raw_token)
    ))
    if session is not None and session.revoked_at is None:
        session.revoked_at = datetime.now(timezone.utc)
        db.commit()
