from datetime import datetime, timezone

from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from .test_allocation_migration import migration_config


def test_populated_creation_receipt_upgrade_preserves_finances_and_unknown_original_intent(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'receipts.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "receipt-migration-secret-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0047_payoff_plan_history")
    engine = create_engine(url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,email,display_name,password_hash,created_at) VALUES ('u','receipt@test.example','Owner','hash',:now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id,name,owner_user_id,created_at) VALUES ('h','Home','u',:now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id,household_id,name,currency_code,allocation_version,created_at) VALUES ('b','h','Budget','USD',0,:now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id,budget_id,name,account_type,is_on_budget,is_closed,created_at) VALUES ('a','b','Checking','checking',1,0,:now)"), {"now": now})
        connection.execute(text("""INSERT INTO transactions
            (id,budget_id,account_id,amount_minor,occurred_on,payee_name,memo,is_cleared,is_reconciled,tags,attachment_metadata,status,created_by_user_id,created_at,client_operation_id)
            VALUES ('t','b','a',-1234,'2026-01-15','Edited merchant','Edited later',1,0,'[]','[]','posted','u',:now,'existing-operation')"""), {"now": now})
        before = connection.execute(text("SELECT * FROM transactions")).mappings().all()
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT * FROM transactions")).mappings().all() == before
        assert connection.execute(text("SELECT budget_id,actor_user_id,operation_id,transaction_id,request_digest FROM transaction_creation_receipts")).one() == ("b", "u", "existing-operation", "t", None)
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == ScriptDirectory.from_config(config).get_current_head()
    command.downgrade(config, "0047_payoff_plan_history")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT * FROM transactions")).mappings().all() == before
