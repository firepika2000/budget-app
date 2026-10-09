from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text


def test_populated_0043_payees_are_backfilled_without_changing_financial_state(tmp_path, monkeypatch):
    database_url = f"sqlite:///{tmp_path / 'payee-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "payee-history-migration-secret-longer-than-32")
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0043_structure_revisions")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users(id,email,display_name,password_hash,created_at) VALUES ('owner','o@example.test','Owner','x','2026-01-01')"))
        connection.execute(text("INSERT INTO households(id,name,owner_user_id,created_at) VALUES ('house','Home','owner','2026-01-01')"))
        connection.execute(text("INSERT INTO memberships(id,household_id,user_id,role,is_active,authorization_version) VALUES ('membership','house','owner','owner',1,0)"))
        connection.execute(text("INSERT INTO budgets(id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','house','Budget','USD',0,'2026-01-01')"))
        connection.execute(text("INSERT INTO category_groups(id,budget_id,name,sort_order,is_archived) VALUES ('group','budget','Needs',0,0)"))
        connection.execute(text("INSERT INTO categories(id,budget_id,group_id,name,sort_order,is_archived,is_essential,is_emergency_fund) VALUES ('category','budget','group','Groceries',0,0,0,0)"))
        connection.execute(text("INSERT INTO accounts(id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('account','budget','Checking','checking',1,0,'2026-01-02')"))
        connection.execute(text("INSERT INTO payees(id,household_id,display_name,name_key,is_archived,created_by_user_id,created_at,updated_at) VALUES ('payee','house','Market','market',0,'owner','2026-01-02','2026-01-02')"))
        connection.execute(text("INSERT INTO payee_aliases(id,payee_id,display_name,name_key,created_by_user_id,created_at) VALUES ('alias','payee','MARKET #42','market #42','owner','2026-01-03')"))
        connection.execute(text("INSERT INTO payee_budget_preferences(id,payee_id,budget_id,default_category_id,updated_by_user_id,updated_at) VALUES ('preference','payee','budget','category','owner','2026-01-04')"))
        connection.execute(text("INSERT INTO transactions(id,budget_id,account_id,payee_id,category_id,amount_minor,occurred_on,payee_name,memo,is_cleared,is_reconciled,status,tags,created_by_user_id,created_at) VALUES ('txn','budget','account','payee','category',-123456,'2026-01-02','Market','',1,0,'posted','[]','owner','2026-01-02')"))

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        rows = connection.execute(text(
            "SELECT budget_id,payee_id,action,actor_user_id,after_snapshot "
            "FROM payee_revisions ORDER BY created_at"
        )).mappings().all()
        assert [(row["budget_id"], row["payee_id"], row["action"], row["actor_user_id"]) for row in rows] == [
            (None, "payee", "created", "owner"),
            ("budget", "payee", "preference_updated", "owner"),
        ]
        assert '"MARKET #42"' in rows[0]["after_snapshot"]
        assert '"default_category_id": "category"' in rows[1]["after_snapshot"]
        assert connection.execute(text("SELECT amount_minor FROM transactions WHERE id='txn'")).scalar_one() == -123456
