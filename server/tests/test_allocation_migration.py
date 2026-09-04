from datetime import datetime, timezone
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text


def test_existing_monthly_assignment_is_backfilled_into_balanced_ledger(
    tmp_path, monkeypatch
):
    database_path = tmp_path / "migration.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv(
        "BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters"
    )
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0005_refresh_sessions")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO users (id, email, display_name, password_hash, created_at) "
            "VALUES ('user-1', 'owner@example.com', 'Owner', 'hash', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO households (id, name, owner_user_id, created_at) "
            "VALUES ('household-1', 'Home', 'user-1', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO budgets (id, household_id, name, currency_code, created_at) "
            "VALUES ('budget-1', 'household-1', 'Family', 'USD', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO category_groups (id, budget_id, name, sort_order) "
            "VALUES ('group-1', 'budget-1', 'Needs', 0)"
        ))
        connection.execute(text(
            "INSERT INTO categories (id, budget_id, group_id, name, sort_order, is_archived) "
            "VALUES ('category-1', 'budget-1', 'group-1', 'Rent', 0, 0)"
        ))
        connection.execute(text(
            "INSERT INTO monthly_assignments "
            "(id, budget_id, category_id, month, assigned_minor) "
            "VALUES ('assignment-1', 'budget-1', 'category-1', '2026-09-01', 125000)"
        ))

    command.upgrade(config, "head")

    with engine.connect() as connection:
        operation = connection.execute(text(
            "SELECT kind, actor_user_id, source FROM allocation_operations"
        )).mappings().one()
        postings = connection.execute(text(
            "SELECT bucket, category_id, amount_minor FROM allocation_postings "
            "ORDER BY bucket"
        )).mappings().all()
        version = connection.execute(text(
            "SELECT allocation_version FROM budgets WHERE id = 'budget-1'"
        )).scalar_one()
        legacy_amount = connection.execute(text(
            "SELECT assigned_minor FROM monthly_assignments WHERE id = 'assignment-1'"
        )).scalar_one()

    assert operation == {
        "kind": "assignment",
        "actor_user_id": "user-1",
        "source": "migration",
    }
    assert sum(item["amount_minor"] for item in postings) == 0
    assert {item["amount_minor"] for item in postings} == {-125000, 125000}
    assert version == 1
    assert legacy_amount == 125000
