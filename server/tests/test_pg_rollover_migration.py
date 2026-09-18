"""Actual PostgreSQL populated 0028→0029 backfill; disposable test database only."""
from datetime import date

from alembic import command
from sqlalchemy import text

from .conftest import auth
from .test_allocation_migration import migration_config
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_pg_concurrency import PG_URL, pg, pg_migrated, pytestmark
from .test_pg_recovery import _rows


def test_pg_populated_rollover_history_backfill_is_batched_and_money_neutral(pg, monkeypatch):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, category = create_budget_structure(pg.client, pg.token, budget["id"])
    record(pg.client, pg.token, budget["id"], account_id=account["id"], amount_minor=10000, occurred_on="2026-09-01")
    record(pg.client, pg.token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-1234, occurred_on="2026-09-02")
    with pg.engine.begin() as connection:
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES (:id, :household, 'Batch proof', 'USD', 0, CURRENT_TIMESTAMP)"),
                           [{"id": f"pg-batch-{index}", "household": budget["household_id"]} for index in range(501)])
    before = _rows(pg.engine)
    before.pop("cash_rollover_policy_changes")
    path = f"/api/v1/budgets/{budget['id']}/months/2026-09-01"
    observation = pg.client.get(path, headers=auth(pg.token)).json()
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", PG_URL)
    config = migration_config()
    command.downgrade(config, "0028_target_snoozes")
    command.upgrade(config, "head")
    after = _rows(pg.engine)
    policies = after.pop("cash_rollover_policy_changes")
    assert len(policies) == 502
    assert after == before
    with pg.engine.connect() as connection:
        assert connection.execute(text("SELECT DISTINCT effective_month, policy, version, source, actor_user_id FROM cash_rollover_policy_changes")).all() == [(date(1, 1, 1), "carry_category_deficit", 0, "legacy_migration", None)]
    assert pg.client.get(path, headers=auth(pg.token)).json() == observation
