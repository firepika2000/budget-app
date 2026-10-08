from datetime import datetime, timezone

from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from .test_allocation_migration import migration_config


def test_legacy_reconciled_account_backfills_one_history_checkpoint(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'reconciliation-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0036_category_resilience")
    engine = create_engine(url)
    stamp = datetime(2026, 9, 30, 16, 30, tzinfo=timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,email,display_name,password_hash,created_at) VALUES ('owner','owner@example.com','Owner','hash',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO households (id,name,owner_user_id,created_at) VALUES ('home','Home','owner',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO budgets (id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','home','Budget','USD',0,:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO accounts (id,budget_id,name,account_type,is_on_budget,is_closed,reconciled_balance_minor,reconciled_at,created_at) VALUES ('checking','budget','Checking','checking',1,0,12345,:stamp,:stamp)"), {"stamp": stamp})

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT budget_id,account_id,actor_user_id,statement_date,statement_balance_minor,cleared_balance_before_minor,reconciled_transaction_count,adjustment_transaction_id FROM reconciliations")).one()
        assert row == ("budget", "checking", "owner", "2026-09-30", 12345, 12345, 0, None)
    engine.dispose()
