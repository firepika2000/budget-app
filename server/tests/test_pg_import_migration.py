"""Disposable populated PostgreSQL upgrade; never human Live."""
import pytest
from alembic import command
from sqlalchemy import text

from .conftest import auth
from .test_allocation_migration import migration_config
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_pg_concurrency import PG_URL, pg, pg_migrated, pytestmark
from .test_pg_recovery import _rows


def test_populated_import_staging_upgrade_and_downgrade_safety(pg, monkeypatch):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, category = create_budget_structure(pg.client, pg.token, budget["id"])
    record(pg.client, pg.token, budget["id"], account_id=account["id"], amount_minor=10000)
    record(pg.client, pg.token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-321)
    path = f"/api/v1/budgets/{budget['id']}/months/2026-09-01"
    observation = pg.client.get(path, headers=auth(pg.token)).json()
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", PG_URL)
    config = migration_config()
    before = _rows(pg.engine)
    assert before.pop("import_batches") == []
    command.downgrade(config, "0029_cash_rollover_history")
    command.upgrade(config, "head")
    after = _rows(pg.engine)
    assert after.pop("import_batches") == []
    assert after == before
    assert pg.client.get(path, headers=auth(pg.token)).json() == observation
    with pg.engine.begin() as connection:
        actor = connection.execute(text("SELECT id FROM users")).scalar_one()
        connection.execute(text("INSERT INTO import_batches (id,budget_id,account_id,created_by_user_id,status,version,candidate_count,candidates,source_format,created_at) VALUES ('review',:budget,:account,:actor,'review',0,0,'[]','csv',CURRENT_TIMESTAMP)"), {"budget": budget["id"], "account": account["id"], "actor": actor})
    assert pg.client.get(path, headers=auth(pg.token)).json() == observation
    with pytest.raises(RuntimeError, match="Cannot remove populated import staging"):
        command.downgrade(config, "0029_cash_rollover_history")
    with pg.engine.connect() as connection:
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0030_import_staging"
        assert connection.execute(text("SELECT COUNT(*) FROM import_batches")).scalar_one() == 1
