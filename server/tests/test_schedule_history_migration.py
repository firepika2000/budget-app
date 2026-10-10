from datetime import datetime, timezone
import json
import io
import re
from types import SimpleNamespace

from alembic import command
from alembic.script import ScriptDirectory
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, text
from sqlalchemy.dialects import postgresql
from app.models import ScheduledTransactionRevision

from .test_allocation_migration import migration_config


def test_schedule_history_migration_indexes_fit_postgres_and_match_orm(monkeypatch):
    migration = ScriptDirectory.from_config(migration_config()).get_revision("0040_schedule_revisions").module
    buffer = io.StringIO()
    context = MigrationContext.configure(dialect_name="postgresql", opts={"as_sql": True, "output_buffer": buffer})
    # Only backfill rows require a live connection. Exercise real PostgreSQL DDL
    # compilation for both directions, with an empty historical schedule set.
    monkeypatch.setattr(migration.op, "get_bind", lambda: SimpleNamespace(execute=lambda _: SimpleNamespace(mappings=lambda: [])))
    with Operations.context(context):
        migration.upgrade()
        migration.downgrade()
    sql = buffer.getvalue()
    created = re.findall(r"CREATE INDEX (\w+)", sql)
    dropped = re.findall(r"DROP INDEX (\w+)", sql)
    assert len(created) == 11 and set(created) == set(dropped)
    assert all(len(name) <= 63 for name in created)
    dialect = postgresql.dialect()
    expected = {dialect.identifier_preparer.format_index(index) for index in ScheduledTransactionRevision.__table__.indexes}
    assert set(created) == expected


def test_populated_schedule_is_backfilled_into_immutable_history(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'schedule-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0039_target_revisions")
    engine = create_engine(url)
    stamp = datetime(2026, 10, 8, 18, 0, tzinfo=timezone.utc)
    exact_amount = -9_007_199_254_740_993  # Cannot round-trip through a Double.
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,email,display_name,password_hash,created_at) VALUES ('owner','owner@example.com','Owner','hash',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO households (id,name,owner_user_id,created_at) VALUES ('home','Home','owner',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO memberships (id,household_id,user_id,role,is_active,authorization_version) VALUES ('membership','home','owner','owner',1,0)"))
        connection.execute(text("INSERT INTO budgets (id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','home','Budget','USD',0,:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO accounts (id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('checking','budget','Checking','checking',1,0,:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO scheduled_transactions (id,budget_id,account_id,name,amount_minor,next_date,recurrence_unit,interval_count,memo,is_active,created_by_user_id,created_at,updated_at) VALUES ('schedule','budget','checking','Rent',:amount,'2026-11-01','months',1,'',1,'owner',:stamp,:stamp)"), {"amount": exact_amount, "stamp": stamp})

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT schedule_id,action,actor_user_id,before_snapshot,after_snapshot,transaction_ids FROM scheduled_transaction_revisions")).mappings().one()
        assert (row["schedule_id"], row["action"], row["actor_user_id"]) == ("schedule", "created", "owner")
        assert json.loads(row["before_snapshot"]) is None
        assert json.loads(row["after_snapshot"])["amount_minor"] == exact_amount
        assert json.loads(row["transaction_ids"]) is None
        assert connection.execute(text("SELECT amount_minor FROM scheduled_transactions WHERE id='schedule'")).scalar_one() == exact_amount
    engine.dispose()
