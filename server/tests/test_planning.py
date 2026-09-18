from datetime import date
from types import SimpleNamespace
import pytest
from fastapi import HTTPException

from app import planning_routes
from app.budgeting_routes import build_smart_funding_preview

from .conftest import auth, freeze_today
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure

# Forecasts anchor "now" on the server's date.today(). These tests assert against
# fixed occurrence dates, so they pin the anchor to a stable reference (the start
# of the budget month under test) instead of the real wall clock.
FORECAST_AS_OF = date(2026, 9, 1)


def test_smart_funding_partial_guidance_and_negative_rta_are_exact():
    category = SimpleNamespace(category_id="category", name="Target", available_minor=2000,
                               recommended_contribution_minor=10000, underfunded_minor=5000)
    summary = SimpleNamespace(month=date(2027, 2, 1), currency_code="USD", allocation_version=1,
                              ready_to_assign_minor=100000, categories=[category])
    preview = build_smart_funding_preview(summary)
    assert preview["proposed_minor"] == 5000
    assert preview["proposals"][0]["after_available_minor"] == 7000
    assert preview["after_ready_to_assign_minor"] == 95000
    summary.ready_to_assign_minor = -100
    preview = build_smart_funding_preview(summary)
    assert preview["proposed_minor"] == 0
    assert preview["proposals"] == []
    assert preview["after_ready_to_assign_minor"] == -100


def test_smart_funding_honors_priority_and_explains_unfunded_need():
    categories = [
        SimpleNamespace(category_id="large", name="Large", available_minor=0,
                        recommended_contribution_minor=90000, underfunded_minor=90000, target_priority=10),
        SimpleNamespace(category_id="urgent", name="Urgent", available_minor=0,
                        recommended_contribution_minor=20000, underfunded_minor=20000, target_priority=90),
    ]
    summary = SimpleNamespace(month=date(2027, 2, 1), currency_code="USD", allocation_version=1,
                              ready_to_assign_minor=30000, categories=categories)
    preview = build_smart_funding_preview(summary)
    assert [p["category_id"] for p in preview["proposals"]] == ["urgent", "large"]
    assert [p["amount_minor"] for p in preview["proposals"]] == [20000, 10000]
    assert preview["remaining_need_minor"] == 80000
    assert preview["unfunded_category_count"] == 1
    categories[0].underfunded_minor = 2**63 - 1
    with pytest.raises(HTTPException) as error:
        build_smart_funding_preview(summary)
    assert error.value.status_code == 422


def test_target_recommendation_uses_rollover_without_mutating_allocation(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 20000},
    )
    assert assigned.status_code == 200
    target = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/target",
        headers=auth(owner_token),
        json={
            "target_type": "target_by_date",
            "target_amount_minor": 120000,
            "target_date": "2026-12-01",
            "priority": 80,
        },
    )
    assert target.status_code == 200

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    row = summary["categories"][0]
    assert summary["ready_to_assign_minor"] == 180000
    assert row["target_type"] == "target_by_date"
    assert row["recommended_contribution_minor"] == 30000
    assert row["underfunded_minor"] == 10000


def test_scheduled_transactions_affect_forecast_but_never_actual_budget(
    client, owner_token, session_factory, monkeypatch
):
    freeze_today(monkeypatch, FORECAST_AS_OF, planning_routes)
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    schedule = client.post(
        f"/api/v1/budgets/{budget['id']}/scheduled-transactions",
        headers=auth(owner_token),
        json={
            "account_id": account["id"],
            "category_id": category["id"],
            "name": "Weekly groceries",
            "amount_minor": -10000,
            "next_date": "2026-09-05",
            "recurrence_unit": "weeks",
            "interval_count": 1,
        },
    )
    assert schedule.status_code == 201

    actual = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    assert actual["ready_to_assign_minor"] == 100000
    assert actual["categories"][0]["activity_minor"] == 0
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
    ).json()[0]["payee_name"] == "Real income"

    forecast = client.get(
        f"/api/v1/budgets/{budget['id']}/forecast?through=2026-09-20",
        headers=auth(owner_token),
    )
    assert forecast.status_code == 200
    data = forecast.json()
    assert data["actual_total_on_budget_minor"] == 100000
    assert data["projected_total_on_budget_minor"] == 70000
    assert data["lowest_projected_total_minor"] == 70000
    assert [item["occurred_on"] for item in data["occurrences"]] == [
        "2026-09-05", "2026-09-12", "2026-09-19"
    ]


def test_scheduled_account_transfer_changes_location_not_total(
    client, owner_token, session_factory, monkeypatch
):
    freeze_today(monkeypatch, FORECAST_AS_OF, planning_routes)
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings", "is_on_budget": True},
    ).json()
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    created = client.post(
        f"/api/v1/budgets/{budget['id']}/scheduled-transactions",
        headers=auth(owner_token),
        json={
            "account_id": checking["id"],
            "destination_account_id": savings["id"],
            "name": "Monthly savings transfer",
            "amount_minor": 25000,
            "next_date": "2026-09-10",
            "recurrence_unit": "months",
        },
    )
    assert created.status_code == 201

    data = client.get(
        f"/api/v1/budgets/{budget['id']}/forecast?through=2026-09-30",
        headers=auth(owner_token),
    ).json()
    by_name = {item["name"]: item for item in data["accounts"]}
    assert by_name["Checking"]["projected_balance_minor"] == 75000
    assert by_name["Savings"]["projected_balance_minor"] == 25000
    assert data["actual_total_on_budget_minor"] == data["projected_total_on_budget_minor"] == 100000


def test_smart_funding_preview_is_nonmutating_and_commit_is_atomic(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    for category, target, priority in ((groceries, 40000, 90), (dining, 30000, 50)):
        response = client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/target",
            headers=auth(owner_token),
            json={"target_type": "monthly_funding", "target_amount_minor": target, "priority": priority},
        )
        assert response.status_code == 200, response.text
    preview = client.get(
        f"/api/v1/budgets/{budget['id']}/smart-funding/2026-09-01", headers=auth(owner_token)
    )
    assert preview.status_code == 200, preview.text
    data = preview.json()
    assert data["before_ready_to_assign_minor"] == 100000
    assert data["proposed_minor"] == 70000
    assert data["after_ready_to_assign_minor"] == 30000
    assert [item["category_name"] for item in data["proposals"]] == ["Groceries", "Dining"]
    unchanged = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    assert unchanged["total_assigned_minor"] == 0
    assert {row["name"]: row["target_priority"] for row in unchanged["categories"]} == {"Groceries": 90, "Dining": 50}
    committed = client.post(
        f"/api/v1/budgets/{budget['id']}/smart-funding", headers=auth(owner_token),
        json={"month": "2026-09-01", "expected_allocation_version": data["allocation_version"]},
    )
    assert committed.status_code == 201, committed.text
    assert committed.json()["kind"] == "smart_funding"
    assert sum(item["amount_minor"] for item in committed.json()["postings"]) == 0
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    assert summary["ready_to_assign_minor"] == 30000
    assert summary["total_assigned_minor"] == 70000

    # A fresh preview must not request the same monthly contribution a second time.
    repeat = client.get(
        f"/api/v1/budgets/{budget['id']}/smart-funding/2026-09-01", headers=auth(owner_token)
    )
    assert repeat.status_code == 200
    assert repeat.json()["proposals"] == []
    assert repeat.json()["proposed_minor"] == 0
