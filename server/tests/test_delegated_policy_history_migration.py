from datetime import datetime, timezone
import json

from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from .test_allocation_migration import migration_config


def test_populated_delegated_policy_is_backfilled_into_immutable_history(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'delegated-policy-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0040_schedule_revisions")
    engine = create_engine(url)
    stamp = datetime(2026, 10, 8, 18, 0, tzinfo=timezone.utc)
    exact = 9_007_199_254_740_992
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,email,display_name,password_hash,created_at) VALUES ('owner','owner@example.com','Owner','hash',:stamp),('child','child@example.com','Child','hash',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO households (id,name,owner_user_id,created_at) VALUES ('home','Home','owner',:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO memberships (id,household_id,user_id,role,is_active,authorization_version) VALUES ('m1','home','owner','owner',1,1),('m2','home','child','child',1,1)"))
        connection.execute(text("INSERT INTO budgets (id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','home','Budget','USD',0,:stamp)"), {"stamp": stamp})
        connection.execute(text("INSERT INTO category_groups (id,budget_id,name,sort_order,is_archived) VALUES ('group','budget','Delegated',0,0)"))
        connection.execute(text("INSERT INTO categories (id,budget_id,group_id,name,delegated_user_id,is_archived,sort_order) VALUES ('pool','budget','group','Pool','child',0,0),('games','budget','group','Games','child',0,1)"))
        connection.execute(text("INSERT INTO delegated_budget_policies (id,budget_id,user_id,pool_category_id,authority_minor,allow_category_creation,allow_reallocation,created_by_user_id,updated_at) VALUES ('policy','budget','child','pool',:exact,1,0,'owner',:stamp)"), {"exact": exact, "stamp": stamp})
        connection.execute(text("INSERT INTO delegated_category_rules (id,policy_id,category_id,rule_kind,minimum_minor,maximum_minor) VALUES ('rule','policy','games','hard_limit',123,NULL)"))

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT member_user_id,action,actor_user_id,before_snapshot,after_snapshot FROM delegated_budget_policy_revisions")).mappings().one()
        assert (row["member_user_id"], row["action"], row["actor_user_id"]) == ("child", "created", "owner")
        assert json.loads(row["before_snapshot"]) is None
        snapshot = json.loads(row["after_snapshot"])
        assert snapshot["authority_minor"] == exact
        assert snapshot["rules"] == [{"category_id": "games", "rule_kind": "hard_limit", "minimum_minor": 123, "maximum_minor": None}]
    engine.dispose()
