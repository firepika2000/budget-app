"""Policy-history foundation must not reinterpret any existing financial fact."""
from datetime import date

from alembic import command
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.exc import IntegrityError

from app.config import Settings
from app.main import create_app
from app.models import CashRolloverPolicyChange, User
from .conftest import auth
from .test_allocation_migration import migration_config
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card


def test_populated_0028_policy_history_upgrade_preserves_rows_and_financial_observations(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'legacy-policy.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0028_target_snoozes")
    engine = create_engine(url, connect_args={"check_same_thread": False})
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    app = create_app(Settings(database_url=url, jwt_secret="migration-test-secret-that-is-longer-than-32-characters", attachment_storage_path=str(tmp_path / "objects")))
    app.state.session_factory = factory
    with TestClient(app) as client:
        boot = client.post("/api/v1/auth/bootstrap", json={"email": "migration@example.com", "password": "long migration test password", "display_name": "Owner", "household_name": "Home"})
        assert boot.status_code == 201, boot.text
        token = boot.json()["access_token"]
        budget = create_budget(client, token, factory)
        account, category = create_budget_structure(client, token, budget["id"])
        card = create_credit_card(client, token, budget["id"])
        root = f"/api/v1/budgets/{budget['id']}"
        # Cross the migration's bounded 500-row batch boundary without loading a household's
        # finances or creating fake user-visible objects in any human database.
        with engine.begin() as connection:
            connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES (:id, :household, 'Batch proof', 'USD', 0, CURRENT_TIMESTAMP)"),
                               [{"id": f"batch-{index}", "household": budget["household_id"]} for index in range(501)])
        record(client, token, budget["id"], account_id=account["id"], amount_minor=50000, occurred_on="2026-09-01")
        assert client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(token), json={"month": "2026-09-01", "assigned_minor": 10000}).status_code == 200
        record(client, token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-10000, occurred_on="2026-09-01")
        record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-15000, occurred_on="2026-09-02")
        paths = [f"{root}/months/{month}" for month in ("2026-09-01", "2026-10-01", "2027-01-01")]
        paths += [f"{root}/accounts/{item['id']}/balance" for item in (account, card)]
        paths += [f"{root}/transactions", f"{root}/allocations"]
        observations = {path: client.get(path, headers=auth(token)).json() for path in paths}
        tables = [name for name in inspect(engine).get_table_names() if name not in ("alembic_version", "refresh_sessions", "audit_events")]
        with engine.connect() as connection:
            before = {name: sorted(connection.execute(text(f'SELECT * FROM "{name}"')).all(), key=repr) for name in tables}
        for revision in ("head", "0028_target_snoozes", "head"):
            (command.upgrade if revision == "head" else command.downgrade)(config, revision)
            with engine.connect() as connection:
                for name, rows in before.items():
                    assert sorted(connection.execute(text(f'SELECT * FROM "{name}"')).all(), key=repr) == rows
                if revision == "head":
                    assert connection.execute(text("SELECT COUNT(*) FROM cash_rollover_policy_changes")).scalar_one() == 502
                    baseline = connection.execute(text("SELECT budget_id, effective_month, policy, version, source, actor_user_id FROM cash_rollover_policy_changes WHERE budget_id=:budget"), {"budget": budget["id"]}).one()
                    assert baseline == (budget["id"], "0001-01-01", "carry_category_deficit", 0, "legacy_migration", None)
            assert {path: client.get(path, headers=auth(token)).json() for path in paths} == observations
        # Downgrade refuses to discard future real decisions, even though this checkpoint does
        # not yet expose policy selection or activate absorption in production projections.
        with engine.begin() as connection:
            actor = connection.execute(text("SELECT id FROM users")).scalar_one()
            connection.execute(text("INSERT INTO cash_rollover_policy_changes (id, budget_id, effective_month, policy, version, source, actor_user_id, created_at) VALUES ('decision', :budget, '2026-10-01', 'absorb_next_month', 1, 'user_selection', :actor, CURRENT_TIMESTAMP)"), {"budget": budget["id"], "actor": actor})
        with pytest.raises(RuntimeError, match="Cannot remove cash rollover history"):
            command.downgrade(config, "0028_target_snoozes")
        with engine.connect() as connection:
            assert connection.execute(text("SELECT COUNT(*) FROM cash_rollover_policy_changes")).scalar_one() == 503
            assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0029_cash_rollover_history"
    engine.dispose()


@pytest.mark.parametrize("overrides", [
    {"policy": "unknown"}, {"version": -1}, {"source": "unknown"},
    {"actor_user_id": None}, {"effective_month": date(2026, 10, 2)},
])
def test_policy_history_storage_rejects_invalid_decisions(client, owner_token, session_factory, overrides):
    budget = create_budget(client, owner_token, session_factory)
    with session_factory() as db:
        values = dict(budget_id=budget["id"], effective_month=date(2026, 10, 1), policy="absorb_next_month",
                      version=1, source="user_selection", actor_user_id=db.query(User.id).scalar())
        values.update(overrides)
        db.add(CashRolloverPolicyChange(**values))
        with pytest.raises(IntegrityError):
            db.commit()


def test_pending_policy_revisions_preserve_each_decision_without_duplicate_versions(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    with session_factory() as db:
        values = dict(budget_id=budget["id"], effective_month=date(2026, 10, 1),
                      source="user_selection", actor_user_id=db.query(User.id).scalar())
        db.add(CashRolloverPolicyChange(**values, version=1, policy="absorb_next_month"))
        db.add(CashRolloverPolicyChange(**values, version=2, policy="carry_category_deficit"))
        db.commit()
        assert db.query(CashRolloverPolicyChange).count() == 2
        db.add(CashRolloverPolicyChange(**values, version=2, policy="absorb_next_month"))
        with pytest.raises(IntegrityError):
            db.commit()
