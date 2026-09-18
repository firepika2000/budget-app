"""Derived cash consumption must remain inside the ordinary PostgreSQL money lock."""
from datetime import date

from app.allocation import ready_to_assign_balance
from app.budgeting_routes import upsert_assignment
from app.schemas import AssignmentUpsert
from .test_cash_rollover_service import setup
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
