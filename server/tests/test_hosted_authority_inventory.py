from datetime import datetime, timezone
import json
from pathlib import Path

from app.config import Settings
from app.database import Base, build_session_factory
from app.models import Budget, Household, Membership, TransactionAttachment, User
from scripts.hosted_authority_inventory import build_inventory


def test_inventory_reports_operational_metadata_without_financial_content(tmp_path: Path):
    database = tmp_path / "authority.sqlite3"
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    factory = build_session_factory(f"sqlite:///{database}")
    Base.metadata.create_all(factory.kw["bind"])
    now = datetime.now(timezone.utc)
    with factory() as session:
        owner = User(id="owner", email="owner@example.com", display_name="Owner", password_hash="hash")
        household = Household(id="household", name="Family", owner_user_id=owner.id, created_at=now)
        budget = Budget(id="budget", household_id=household.id, name="Home", currency_code="USD")
        session.add_all([
            owner,
            household,
            Membership(id="membership", household_id=household.id, user_id=owner.id, role="owner", is_active=True),
            budget,
            TransactionAttachment(
                id="attachment", budget_id=budget.id, transaction_id="transaction",
                filename="receipt.jpg", content_type="image/jpeg", byte_count=3,
                sha256="0" * 64, storage_key="stored-object", created_by_user_id=owner.id,
            ),
        ])
        session.commit()
        (attachments / "stored-object").write_bytes(b"encrypted")
        settings = Settings(
            database_url=f"sqlite:///{database}", jwt_secret="x" * 32,
            attachment_storage_path=str(attachments),
        )
        result = build_inventory(session, settings)

    assert result["summary"]["households"] == 1
    assert result["summary"]["users"] == 1
    assert result["summary"]["budgets"] == 1
    assert result["summary"]["database_bytes"] > 0
    assert result["summary"]["attachment_bytes"] == len(b"encrypted")
    row = result["households"][0]
    assert row["owner_email"] == "owner@example.com"
    assert row["members"] == 1
    assert row["budgets"] == 1
    assert row["attachments"] == 1
    assert row["attachment_logical_bytes"] == 3
    assert row["attachment_stored_bytes"] == len(b"encrypted")
    serialized = json.dumps(result)
    assert "amount_minor" not in serialized
    assert "payee" not in serialized
    assert "memo" not in serialized
