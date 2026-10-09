from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text


def test_populated_0044_allowance_is_backfilled_without_changing_financial_state(tmp_path, monkeypatch):
    database_url = f"sqlite:///{tmp_path / 'allowance-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "allowance-history-migration-secret-longer-than-32")
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0044_payee_revisions")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users(id,email,display_name,password_hash,created_at) VALUES ('owner','o@example.test','Owner','x','2026-01-01')"))
        connection.execute(text("INSERT INTO households(id,name,owner_user_id,created_at) VALUES ('house','Home','owner','2026-01-01')"))
        connection.execute(text("INSERT INTO memberships(id,household_id,user_id,role,is_active,authorization_version) VALUES ('membership','house','owner','owner',1,0)"))
        connection.execute(text("INSERT INTO budgets(id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','house','Budget','USD',0,'2026-01-01')"))
        connection.execute(text("INSERT INTO category_groups(id,budget_id,name,sort_order,is_archived) VALUES ('group','budget','Needs',0,0)"))
        connection.execute(text("INSERT INTO categories(id,budget_id,group_id,name,sort_order,is_archived,is_essential,is_emergency_fund) VALUES ('source','budget','group','Pool',0,0,0,0),('destination','budget','group','Spending',1,0,0,0)"))
        connection.execute(text("INSERT INTO accounts(id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('account','budget','Checking','checking',1,0,'2026-01-02')"))
        connection.execute(text("INSERT INTO transactions(id,budget_id,account_id,category_id,amount_minor,occurred_on,payee_name,memo,is_cleared,is_reconciled,status,tags,created_by_user_id,created_at) VALUES ('txn','budget','account','destination',-123456,'2026-01-02','Market','',1,0,'posted','[]','owner','2026-01-02')"))
        connection.execute(text("INSERT INTO allowance_plans(id,budget_id,delegated_user_id,source_category_id,name,amount_minor,next_issue_date,recurrence_unit,interval_count,rollover_policy,is_active,created_by_user_id,created_at) VALUES ('plan','budget','owner','source','Weekly',2000,'2026-10-09','week',1,'rollover',1,'owner','2026-01-03')"))
        connection.execute(text("INSERT INTO allowance_splits(id,plan_id,destination_category_id,amount_minor) VALUES ('split','plan','destination',2000)"))

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT plan_id,action,actor_user_id,after_snapshot FROM allowance_plan_revisions")).mappings().one()
        assert (row["plan_id"], row["action"], row["actor_user_id"]) == ("plan", "created", "owner")
        assert '"amount_minor": 2000' in row["after_snapshot"]
        assert '"destination_category_id": "destination"' in row["after_snapshot"]
        assert connection.execute(text("SELECT amount_minor FROM transactions WHERE id='txn'")).scalar_one() == -123456
