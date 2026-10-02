"""Read-only host inventory for owner-operated ClearPocket deployments.

This intentionally reports operational metadata, never financial amounts or transaction content.
It is executed inside the application container so schema knowledge remains application-owned.
"""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
from typing import Any

from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from app.config import Settings
from app.database import build_session_factory
from app.models import Budget, Household, Membership, Transaction, TransactionAttachment, User


def _database_size(session: Session, database_url: str) -> int:
    if database_url.startswith("postgresql"):
        return int(session.scalar(text("SELECT pg_database_size(current_database())")) or 0)
    if database_url.startswith("sqlite"):
        location = database_url.split("///", 1)[-1]
        if location != ":memory:":
            path = Path(location)
            return path.stat().st_size if path.is_file() else 0
    return 0


def _stored_attachment_bytes(root: Path, storage_keys: list[str]) -> int:
    total = 0
    for key in storage_keys:
        if not key or Path(key).name != key:
            continue
        path = root / key
        try:
            if path.is_file() and not path.is_symlink():
                total += path.stat().st_size
        except OSError:
            continue
    return total


def build_inventory(session: Session, settings: Settings) -> dict[str, Any]:
    attachment_root = Path(settings.attachment_storage_path)
    household_rows: list[dict[str, Any]] = []
    all_storage_keys: list[str] = []

    households = session.execute(
        select(Household, User)
        .join(User, User.id == Household.owner_user_id)
        .order_by(func.lower(Household.name), Household.id)
    ).all()
    for household, owner in households:
        budget_ids = list(session.scalars(select(Budget.id).where(Budget.household_id == household.id)))
        member_count = int(session.scalar(select(func.count()).select_from(Membership).where(
            Membership.household_id == household.id,
            Membership.is_active.is_(True),
        )) or 0)
        transaction_count = 0
        last_activity: datetime | None = None
        attachment_count = 0
        logical_attachment_bytes = 0
        storage_keys: list[str] = []
        if budget_ids:
            transaction_count = int(session.scalar(select(func.count()).select_from(Transaction).where(
                Transaction.budget_id.in_(budget_ids)
            )) or 0)
            last_activity = session.scalar(select(func.max(Transaction.created_at)).where(
                Transaction.budget_id.in_(budget_ids)
            ))
            attachments = session.execute(select(
                TransactionAttachment.storage_key,
                TransactionAttachment.byte_count,
            ).where(TransactionAttachment.budget_id.in_(budget_ids))).all()
            storage_keys = [str(row.storage_key) for row in attachments]
            attachment_count = len(attachments)
            logical_attachment_bytes = sum(int(row.byte_count) for row in attachments)
            all_storage_keys.extend(storage_keys)
        household_rows.append({
            "id": household.id,
            "name": household.name,
            "owner_display_name": owner.display_name,
            "owner_email": owner.email,
            "members": member_count,
            "budgets": len(budget_ids),
            "transactions": transaction_count,
            "attachments": attachment_count,
            "attachment_logical_bytes": logical_attachment_bytes,
            "attachment_stored_bytes": _stored_attachment_bytes(attachment_root, storage_keys),
            "created_at": household.created_at.isoformat(),
            "last_activity_at": last_activity.isoformat() if last_activity else None,
        })

    database_bytes = _database_size(session, settings.database_url)
    attachment_bytes = _stored_attachment_bytes(attachment_root, all_storage_keys)
    return {
        "summary": {
            "households": len(household_rows),
            "users": int(session.scalar(select(func.count()).select_from(User)) or 0),
            "budgets": int(session.scalar(select(func.count()).select_from(Budget)) or 0),
            "database_bytes": database_bytes,
            "attachment_bytes": attachment_bytes,
            "total_bytes": database_bytes + attachment_bytes,
        },
        "households": household_rows,
        "privacy": "Operational metadata only; financial amounts and transaction content are excluded.",
    }


def main() -> None:
    settings = Settings.from_environment()
    factory = build_session_factory(settings.database_url)
    with factory() as session:
        print(json.dumps(build_inventory(session, settings), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
