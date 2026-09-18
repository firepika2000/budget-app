"""Disposable report-scale evidence; elapsed time is recorded, not a machine-dependent gate."""
from datetime import date, timedelta
from time import perf_counter

from sqlalchemy import event, insert, select

from app.models import Transaction, User
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure


def test_summary_payload_stays_bounded_across_ten_thousand_transactions(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    for _ in range(10):
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    with session_factory() as session:
        engine = session.get_bind()
        owner_id = session.scalar(select(User.id))
    url = f"/api/v1/budgets/{budget['id']}/reports/summary?start_date=2018-01-01&end_date=2026-09-30"

    def measure():
        statements = 0

        def count(*_):
            nonlocal statements
            statements += 1

        event.listen(engine, "before_cursor_execute", count)
        started = perf_counter()
        try:
            response = client.get(url, headers=auth(owner_token))
        finally:
            elapsed = perf_counter() - started
            event.remove(engine, "before_cursor_execute", count)
        assert response.status_code == 200, response.text
        return response, statements, elapsed

    small, small_queries, small_seconds = measure()
    # Synthetic bulk setup is confined to the disposable in-memory fixture, not an application
    # mutation/import path. Financial observations still come from the real production HTTP route.
    with session_factory() as session:
        session.execute(insert(Transaction), [{
            "budget_id": budget["id"], "account_id": account["id"], "category_id": category["id"],
            "amount_minor": -100, "occurred_on": date(2018, 1, 1) + timedelta(days=index % 2500),
            "payee_name": "Synthetic scale receipt", "created_by_user_id": owner_id,
        } for index in range(9990)])
        session.commit()
    large, large_queries, large_seconds = measure()
    assert small.json()["net_cash_flow_minor"] == -1000
    assert large.json()["net_cash_flow_minor"] == -1_000_000
    assert len(large.content) < 512
    assert len(large.content) - len(small.content) < 32
    # Select-in relationship batches are allowed; one query per transaction is not.
    assert large_queries < small_queries + 200
    print(f"summary_scale rows=10 bytes={len(small.content)} sql={small_queries} seconds={small_seconds:.4f}")
    print(f"summary_scale rows=10000 bytes={len(large.content)} sql={large_queries} seconds={large_seconds:.4f}")
