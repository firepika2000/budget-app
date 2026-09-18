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


def test_forecast_tracks_intermediate_low_and_atomic_transfer_without_posting(
    client, owner_token, session_factory, monkeypatch
):
    from app import analytics_routes, budgeting_routes
    freeze_today(monkeypatch, date(2026, 9, 5), planning_routes, analytics_routes, budgeting_routes)
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    savings = client.post(f"{root}/accounts", headers=auth(owner_token), json={"name": "Savings", "account_type": "savings"}).json()
    fund(client, owner_token, budget["id"], checking["id"], amount=10000, occurred_on="2026-09-01")
    for fields in [
        {"name": "Later income", "amount_minor": 9000, "next_date": "2026-09-20"},
        {"name": "Early bill", "amount_minor": -8000, "next_date": "2026-09-10", "category_id": category["id"]},
        {"name": "Internal transfer", "amount_minor": 5000, "next_date": "2026-09-12", "destination_account_id": savings["id"]},
    ]:
        response = client.post(f"{root}/scheduled-transactions", headers=auth(owner_token), json={
            "account_id": checking["id"], "recurrence_unit": "once", **fields,
        })
        assert response.status_code == 201, response.text
    before = client.get(f"{root}/transactions", headers=auth(owner_token)).json()
    for _ in range(2):
        response = client.get(f"{root}/forecast?through=2026-12-04", headers=auth(owner_token))
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["actual_total_on_budget_minor"] == 10000
        assert body["projected_total_on_budget_minor"] == 11000
        assert body["lowest_projected_total_minor"] == 2000
        assert [row["name"] for row in body["occurrences"]] == ["Early bill", "Internal transfer", "Later income"]
        assert {row["account_id"]: row["projected_balance_minor"] for row in body["accounts"]} == {checking["id"]: 6000, savings["id"]: 5000}
        resilience = client.get(f"{root}/reports/resilience?horizon_days=90", headers=auth(owner_token)).json()
        assert resilience["lowest_projected_on_budget_minor"] == 2000
        assert resilience["scheduled_income_minor"] == 9000
        assert resilience["scheduled_outflows_minor"] == 8000
        assert client.get(f"{root}/transactions", headers=auth(owner_token)).json() == before
        assert client.get(f"{root}/accounts/{checking['id']}/balance", headers=auth(owner_token)).json()["working_balance_minor"] == 10000


def test_forecast_and_resilience_apply_schedule_category_scope_before_projection(
    client, owner_token, session_factory, monkeypatch
):
    from app import analytics_routes
    from .test_delegated_access import add_child, configure_child

    freeze_today(monkeypatch, FORECAST_AS_OF, planning_routes, analytics_routes)
    budget = create_budget(client, owner_token, session_factory)
    account, hidden_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Delegated", "Visible")
    root = f"/api/v1/budgets/{budget['id']}"
    schedules = []
    for name, category, amount, day in [
        ("Visible bill", visible_category["id"], -700, "2026-09-10"),
        ("Secret household bill", hidden_category["id"], -12345, "2026-09-11"),
        ("Secret future salary", None, 99999, "2026-09-12"),
    ]:
        response = client.post(f"{root}/scheduled-transactions", headers=auth(owner_token), json={
            "account_id": account["id"], "category_id": category, "name": name,
            "amount_minor": amount, "next_date": day, "recurrence_unit": "once",
        })
        assert response.status_code == 201, response.text
        schedules.append(response.json())
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, account["id"], visible_category["id"])
    profile = {
        "capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [visible_category["id"]],
    }
    assert client.put(f"{root}/access/{child_id}", headers=auth(owner_token), json=profile).status_code == 200
    before = client.get(f"{root}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
    listed = client.get(f"{root}/scheduled-transactions", headers=auth(child_token))
    assert listed.status_code == 200
    assert [item["id"] for item in listed.json()] == [schedules[0]["id"]]

    projection = client.get(f"{root}/forecast?through=2026-09-30", headers=auth(child_token))
    assert projection.status_code == 200, projection.text
    assert [item["scheduled_transaction_id"] for item in projection.json()["occurrences"]] == [schedules[0]["id"]]
    assert projection.json()["projected_total_on_budget_minor"] == -700
    assert projection.json()["lowest_projected_total_minor"] == -700
    for hidden in schedules[1:]:
        assert hidden["name"] not in projection.text and hidden["id"] not in projection.text
    resilience = client.get(f"{root}/reports/resilience", headers=auth(child_token))
    assert resilience.status_code == 200, resilience.text
    assert resilience.json()["scheduled_income_minor"] == 0
    assert resilience.json()["scheduled_outflows_minor"] == 700
    assert resilience.json()["expected_margin_minor"] == -700
    assert resilience.json()["lowest_projected_on_budget_minor"] == -700

    profile["category_ids"] = []
    assert client.put(f"{root}/access/{child_id}", headers=auth(owner_token), json=profile).status_code == 200
    assert client.get(f"{root}/forecast?through=2026-09-30", headers=auth(child_token)).json()["occurrences"] == []
    empty = client.get(f"{root}/reports/resilience", headers=auth(child_token)).json()
    assert empty["scheduled_income_minor"] == empty["scheduled_outflows_minor"] == empty["projected_on_budget_minor"] == 0

    # An explicit unrestricted category grant may see all three; owner behavior is unchanged.
    profile["restrict_categories"] = False
    assert client.put(f"{root}/access/{child_id}", headers=auth(owner_token), json=profile).status_code == 200
    for token in [owner_token, child_token]:
        full = client.get(f"{root}/forecast?through=2026-09-30", headers=auth(token)).json()
        assert {item["scheduled_transaction_id"] for item in full["occurrences"]} == {item["id"] for item in schedules}
        assert full["projected_total_on_budget_minor"] == 86954
    assert client.get(f"{root}/accounts/{account['id']}/balance", headers=auth(owner_token)).json() == before
    assert client.get(f"{root}/transactions", headers=auth(owner_token)).json() == []


def test_historical_smart_funding_cannot_spend_money_assigned_in_later_month(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=50000, occurred_on="2026-08-01")
    root = f"/api/v1/budgets/{budget['id']}"
    headers = auth(owner_token)
    assert client.put(f"{root}/categories/{category['id']}/target", headers=headers,
                      json={"target_type": "monthly_funding", "target_amount_minor": 30000}).status_code == 200
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
                      json={"month": "2026-09-01", "assigned_minor": 50000}).status_code == 200
    before = client.get(f"{root}/months/2026-09-01", headers=headers).json()
    assert before["ready_to_assign_minor"] == 0
    historical = client.get(f"{root}/months/2026-08-01", headers=headers).json()
    assert historical["ready_to_assign_minor"] == 50000  # historical observation remains true
    preview = client.get(f"{root}/smart-funding/2026-08-01", headers=headers)
    assert preview.status_code == 200
    assert preview.json()["before_ready_to_assign_minor"] == 50000
    assert preview.json()["funding_limit_minor"] == 0
    assert preview.json()["proposed_minor"] == 0
    assert preview.json()["remaining_need_minor"] == 30000
    attempted = client.post(f"{root}/smart-funding", headers=headers,
                            json={"month": "2026-08-01", "expected_allocation_version": before["allocation_version"]})
    after = client.get(f"{root}/months/2026-09-01", headers=headers).json()
    assert attempted.status_code == 409, f"Historical funding returned {attempted.status_code}, current RTA became {after['ready_to_assign_minor']}"
    assert after == before


def test_historical_smart_funding_caps_partial_availability_and_preserves_assets(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=50000, occurred_on="2026-08-01")
    root = f"/api/v1/budgets/{budget['id']}"
    headers = auth(owner_token)
    assert client.put(f"{root}/categories/{category['id']}/target", headers=headers,
                      json={"target_type": "monthly_funding", "target_amount_minor": 30000}).status_code == 200
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
                      json={"month": "2026-09-01", "assigned_minor": 40000}).status_code == 200
    before_balance = client.get(f"{root}/accounts/{account['id']}/balance", headers=headers).json()
    preview = client.get(f"{root}/smart-funding/2026-08-01", headers=headers).json()
    assert preview["before_ready_to_assign_minor"] == 50000
    assert preview["funding_limit_minor"] == preview["proposed_minor"] == 10000
    assert preview["after_ready_to_assign_minor"] == 40000
    assert preview["remaining_need_minor"] == 20000
    committed = client.post(f"{root}/smart-funding", headers=headers,
                            json={"month": "2026-08-01", "expected_allocation_version": preview["allocation_version"]})
    assert committed.status_code == 201
    assert sum(p["amount_minor"] for p in committed.json()["postings"]) == 0
    assert client.get(f"{root}/months/2026-09-01", headers=headers).json()["ready_to_assign_minor"] == 0
    assert client.get(f"{root}/accounts/{account['id']}/balance", headers=headers).json() == before_balance
    assert client.get(f"{root}/smart-funding/2026-08-01", headers=headers).json()["proposed_minor"] == 0


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
