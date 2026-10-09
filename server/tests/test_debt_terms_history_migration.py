from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text


def test_populated_0045_debt_terms_are_backfilled_without_changing_financial_state(tmp_path, monkeypatch):
    database_url = f"sqlite:///{tmp_path / 'debt-terms-history.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "debt-terms-history-migration-secret-longer-than-32")
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0045_allowance_plan_history")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users(id,email,display_name,password_hash,created_at) VALUES ('owner','o@example.test','Owner','x','2026-01-01')"))
        connection.execute(text("INSERT INTO households(id,name,owner_user_id,created_at) VALUES ('house','Home','owner','2026-01-01')"))
        connection.execute(text("INSERT INTO memberships(id,household_id,user_id,role,is_active,authorization_version) VALUES ('membership','house','owner','owner',1,0)"))
        connection.execute(text("INSERT INTO budgets(id,household_id,name,currency_code,allocation_version,created_at) VALUES ('budget','house','Budget','USD',0,'2026-01-01')"))
        connection.execute(text("INSERT INTO accounts(id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('card','budget','Card','credit',1,0,'2026-01-02')"))
        connection.execute(text("INSERT INTO transactions(id,budget_id,account_id,amount_minor,occurred_on,payee_name,memo,is_cleared,is_reconciled,status,tags,created_by_user_id,created_at) VALUES ('txn','budget','card',-123456,'2026-01-02','Market','',1,0,'posted','[]','owner','2026-01-02')"))
        connection.execute(text("INSERT INTO account_debt_terms(account_id,budget_id,terms_type,annual_rate_basis_points,rate_type,payment_frequency,minimum_payment_rule,minimum_payment_minor,due_day,updated_at) VALUES ('card','budget','credit_card',2199,'variable','monthly','fixed',9007199254740993,18,'2026-01-03')"))

    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
        row = connection.execute(text("SELECT account_id,action,actor_user_id,after_snapshot FROM account_debt_terms_revisions")).mappings().one()
        assert (row["account_id"], row["action"], row["actor_user_id"]) == ("card", "created", "owner")
        assert '"annual_rate_basis_points": 2199' in row["after_snapshot"]
        assert '"minimum_payment_minor": 9007199254740993' in row["after_snapshot"]
        assert connection.execute(text("SELECT amount_minor FROM transactions WHERE id='txn'")).scalar_one() == -123456
