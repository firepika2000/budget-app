from datetime import datetime, timezone
import json

from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from .test_allocation_migration import migration_config


def test_populated_target_is_backfilled_into_immutable_history(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'target-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0038_debt_payoff_plan")
    engine = create_engine(url)
    stamp = datetime(2026, 10, 8, 17, 0, tzinfo=timezone.utc)
    exact_amount = 9_007_199_254_740_993  # Cannot round-trip through a Double.
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,email,display_name,password_hash,created_at) VALUES ('owner','owner@example.com','Owner','hash',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO households (id,name,owner_user_id,created_at) VALUES ('home','Home','owner',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO memberships (id,household_id,user_id,role,is_active,authorization_version) VALUES ('membership','home','owner','owner',1,0)"))
        connection.execute(text("INSERT INTO budgets (id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','home','Budget','USD',0,:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO category_groups (id,budget_id,name,sort_order,is_archived) VALUES ('needs','budget','Needs',0,0)"))
        connection.execute(text("INSERT INTO categories (id,budget_id,group_id,name,sort_order,is_archived) VALUES ('groceries','budget','needs','Groceries',0,0)"))
        connection.execute(text("INSERT INTO category_targets (id,budget_id,category_id,target_type,target_amount_minor,target_date,recurrence_months,minimum_contribution_minor,priority,is_active,created_by_user_id,created_at,updated_at) VALUES ('target','budget','groceries','target_by_date',:amount,'2027-06-01',NULL,5000,80,1,'owner',:stamp,:stamp)"), {"amount": exact_amount, "stamp": stamp})

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT budget_id,category_id,target_id,action,actor_user_id,before_snapshot,after_snapshot,created_at FROM category_target_revisions")).mappings().one()
        assert (row["budget_id"], row["category_id"], row["target_id"], row["action"], row["actor_user_id"]) == ("budget", "groceries", "target", "created", "owner")
        assert json.loads(row["before_snapshot"]) is None
        assert json.loads(row["after_snapshot"])["target_amount_minor"] == exact_amount
        assert str(row["created_at"]).startswith("2026-10-08 17:00:00")
        assert connection.execute(text("SELECT target_amount_minor FROM category_targets WHERE id='target'")).scalar_one() == exact_amount
    engine.dispose()
