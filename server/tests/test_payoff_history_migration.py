import json
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text


def test_populated_payoff_plan_history_upgrade_and_downgrade(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'payoff-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "payoff-history-migration-secret-longer-than-32")
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0046_debt_terms_history")
    engine = create_engine(url)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users(id,email,display_name,password_hash,created_at) VALUES ('owner','o@example.test','Owner','x','2026-01-01')"))
        connection.execute(text("INSERT INTO households(id,name,owner_user_id,created_at) VALUES ('house','Home','owner','2026-01-01')"))
        connection.execute(text("INSERT INTO budgets(id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','house','Budget','USD',0,'2026-01-01')"))
        connection.execute(text("INSERT INTO accounts(id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('card','budget','Card','credit',1,0,'2026-01-02')"))
        connection.execute(text("INSERT INTO transactions(id,budget_id,account_id,amount_minor,occurred_on,payee_name,memo,is_cleared,is_reconciled,status,tags,created_by_user_id,created_at) VALUES ('txn','budget','card',-123456,'2026-01-02','Market','',1,0,'posted','[]','owner','2026-01-02')"))
        connection.execute(text("INSERT INTO debt_payoff_plans(id,budget_id,user_id,strategy,rollover,extra_payment_minor,account_ids,custom_order,target_date,updated_at) VALUES ('plan','budget','owner','custom',1,9007199254740993,'[\"card\"]','[\"card\"]','2028-02-29','2026-01-03')"))
        original = connection.execute(text("SELECT * FROM debt_payoff_plans")).mappings().one()
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT * FROM debt_payoff_plan_revisions")).mappings().one()
        assert (row["budget_id"], row["user_id"], row["action"]) == ("budget", "owner", "created")
        assert json.loads(row["after_snapshot"]) == {
            "strategy": "custom", "rollover": True, "extra_payment_minor": 9007199254740993,
            "account_ids": ["card"], "custom_order": ["card"], "target_date": "2028-02-29"}
        assert connection.execute(text("SELECT * FROM debt_payoff_plans")).mappings().one() == original
        assert connection.execute(text("SELECT amount_minor FROM transactions WHERE id='txn'")).scalar_one() == -123456
    command.downgrade(config, "0046_debt_terms_history")
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM debt_payoff_plan_revisions")).scalar_one() == 1
        assert connection.execute(text("SELECT * FROM debt_payoff_plans")).mappings().one() == original
