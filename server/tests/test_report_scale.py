"""Disposable report-scale evidence; elapsed time is recorded, not a machine-dependent gate."""
from datetime import date, timedelta
from time import perf_counter

import pytest
from sqlalchemy import event, insert, select

from app.models import AllocationOperation, AllocationPosting, Budget, Transaction, TransactionSplit, User
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund


@pytest.mark.parametrize("large_allocations", [False, True])
def test_month_summary_bounds_orm_hydration_with_ten_thousand_split_and_direct_rows(client, owner_token, session_factory, large_allocations):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    other = add_category(client, owner_token, budget["id"], "Other", "Split destination")
    fund(client, owner_token, budget["id"], account["id"], amount=100000, occurred_on="2026-08-01")
    root = f"/api/v1/budgets/{budget['id']}"
    for month, amount in (("2026-08-01", 50000), ("2026-09-01", 10000)):
        assert client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
                          json={"month": month, "assigned_minor": amount}).status_code == 200
    with session_factory() as session:
        owner_id = session.scalar(select(User.id))
        rows, splits = [], []
        for index in range(10000):
            identifier = f"scale-month-{index}"
            split = index % 2 == 0
            rows.append({"id": identifier, "budget_id": budget["id"], "account_id": account["id"],
                         "category_id": None if split else category["id"], "amount_minor": -3 if split else -1,
                         "occurred_on": date(2026, 8, 31) if index < 4000 else date(2026, 9, 1),
                         "payee_name": "Disposable scale receipt", "created_by_user_id": owner_id})
            if split:
                splits.extend([{"transaction_id": identifier, "category_id": item["id"], "amount_minor": amount}
                               for item, amount in ((category, -1), (other, -2))])
        session.execute(insert(Transaction), rows)
        session.execute(insert(TransactionSplit), splits)
        if large_allocations:
            session.execute(insert(AllocationOperation), [{
                "id": f"scale-allocation-{index}", "budget_id": budget["id"], "actor_user_id": owner_id,
                "occurred_on": date(2026, 8, 31) if index < 4000 else date(2026, 9, 1),
                "kind": "assignment", "note": "Disposable allocation history",
            } for index in range(10000)])
            session.execute(insert(AllocationPosting), [{
                "operation_id": f"scale-allocation-{index}", "budget_id": budget["id"],
                "bucket": bucket, "category_id": category_id, "amount_minor": amount,
            } for index in range(10000) for bucket, category_id, amount in (
                ("ready_to_assign", None, -1), ("category", category["id"], 1),
            )])
            session.get(Budget, budget["id"]).allocation_version += 10000
        session.commit()
    peak_objects = 0

    def loaded(session, _instance):
        nonlocal peak_objects
        peak_objects = max(peak_objects, len(session.identity_map))

    event.listen(session_factory.class_, "loaded_as_persistent", loaded)
    started = perf_counter()
    try:
        response = client.get(f"{root}/months/2026-09-01", headers=auth(owner_token))
    finally:
        elapsed = perf_counter() - started
        event.remove(session_factory.class_, "loaded_as_persistent", loaded)
    assert response.status_code == 200, response.text
    result = response.json()
    categories = {row["category_id"]: row for row in result["categories"]}
    assert result["ready_to_assign_minor"] == (30000 if large_allocations else 40000)
    assert categories[category["id"]]["assigned_minor"] == (16000 if large_allocations else 10000)
    assert categories[category["id"]]["carried_available_minor"] == (50000 if large_allocations else 46000)
    assert categories[category["id"]]["activity_minor"] == -6000
    assert categories[category["id"]]["available_minor"] == (60000 if large_allocations else 50000)
    assert categories[other["id"]]["available_minor"] == -10000
    print(f"month_scale transactions=10000 splits=10000 large_allocations={large_allocations} peak_orm={peak_objects} bytes={len(response.content)} seconds={elapsed:.4f}")
    assert len(response.content) < 5000
    assert peak_objects < 3000  # batch bound, not a timing assertion tied to this machine


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
