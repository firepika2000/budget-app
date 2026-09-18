"""Derived cash consumption must remain inside the ordinary PostgreSQL money lock."""
from datetime import date

from app.allocation import ready_to_assign_balance
from app.budgeting_routes import upsert_assignment
from app.schemas import AssignmentUpsert
from .test_cash_rollover_service import setup
from .conftest import freeze_today
from .test_budgeting_api import create_budget
from .test_pg_concurrency import pg, pg_migrated, pytestmark, outcomes, route_attempt, run_race


def test_concurrent_assignments_cannot_spend_absorbed_cash(pg):
    budget, _, category, _ = setup(pg.client, pg.token, pg.factory)

    def attempt(month):
        def call(db, user):
            return upsert_assignment(budget_id=budget["id"], category_id=category["id"],
                body=AssignmentUpsert(month=month, assigned_minor=20000), user=user, db=db)
        return route_attempt(pg.factory, pg.owner_id, call)

    assert outcomes(run_race([attempt(date(2026, 10, 1)), attempt(date(2026, 11, 1))])) == ["conflict", "ok"]
    with pg.factory() as db:
        assert ready_to_assign_balance(db, budget["id"]) == 15000


def test_concurrent_policy_changes_append_once_and_invalidate_once(pg, monkeypatch):
    from app import rollover_routes
    from app.models import Budget, CashRolloverPolicyChange
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    budget = create_budget(pg.client, pg.token, pg.factory)
    body = rollover_routes.PolicySelection(policy="absorb_next_month", effective_month=date(2026, 10, 1),
        expected_policy_version=0, expected_allocation_version=0)

    def call(db, user):
        return rollover_routes.select_policy(budget_id=budget["id"], body=body, user=user, db=db)

    result = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(result) == ["conflict", "ok"]
    with pg.factory() as db:
        assert db.get(Budget, budget["id"]).allocation_version == 1
        assert db.query(CashRolloverPolicyChange).filter_by(budget_id=budget["id"]).count() == 2
