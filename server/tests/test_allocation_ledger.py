from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure


def fund(client, owner_token, budget_id, account_id, amount=100000, occurred_on="2026-09-01"):
    return record(
        client,
        owner_token,
        budget_id,
        account_id=account_id,
        amount_minor=amount,
        occurred_on=occurred_on,
        payee_name="Real income",
        is_cleared=True,
    )


def test_assignments_and_category_transfers_are_balanced_and_auditable(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    fuel = add_category(client, owner_token, budget["id"], "Needs", "Fuel")
    fund(client, owner_token, budget["id"], account["id"])

    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={
            "month": "2026-09-01",
            "assigned_minor": 50000,
            "expected_allocation_version": 0,
        },
    )
    assert assigned.status_code == 200
    assert assigned.json()["allocation_version"] == 1

    stale = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{fuel['id']}/assignment",
        headers=auth(owner_token),
        json={
            "month": "2026-09-01",
            "assigned_minor": 1000,
            "expected_allocation_version": 0,
        },
    )
    assert stale.status_code == 409
    assert stale.json()["detail"]["current_allocation_version"] == 1

    moved = client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers",
        headers=auth(owner_token),
        json={
            "source_category_id": groceries["id"],
            "destination_category_id": fuel["id"],
            "amount_minor": 10000,
            "occurred_on": "2026-09-04",
            "note": "Fuel became the priority",
            "expected_allocation_version": 1,
        },
    )
    assert moved.status_code == 201
    assert moved.json()["allocation_version"] == 2
    assert sum(item["amount_minor"] for item in moved.json()["postings"]) == 0

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    by_name = {item["name"]: item for item in summary["categories"]}
    assert summary["ready_to_assign_minor"] == 50000
    assert by_name["Groceries"]["available_minor"] == 40000
    assert by_name["Fuel"]["available_minor"] == 10000

    history = client.get(
        f"/api/v1/budgets/{budget['id']}/allocations",
        headers=auth(owner_token),
    ).json()
    assert [item["kind"] for item in history] == ["category_transfer", "assignment"]
    assert all(sum(posting["amount_minor"] for posting in item["postings"]) == 0 for item in history)


def test_category_balance_rolls_forward_across_multiple_months(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=500000, occurred_on="2026-01-01")
    january = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-01-01", "assigned_minor": 50000, "expected_allocation_version": 0},
    )
    assert january.status_code == 200
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        category_id=category["id"],
        amount_minor=-10000,
        occurred_on="2026-01-15",
    )
    february = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-02-01", "assigned_minor": 50000, "expected_allocation_version": 1},
    )
    assert february.status_code == 200
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        category_id=category["id"],
        amount_minor=-25000,
        occurred_on="2026-02-10",
    )

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-02-01",
        headers=auth(owner_token),
    ).json()
    row = summary["categories"][0]
    assert row["carried_available_minor"] == 40000
    assert row["assigned_minor"] == 50000
    assert row["activity_minor"] == -25000
    assert row["available_minor"] == 65000


def test_real_money_and_planning_boundaries_are_enforced(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=1000)
    overassigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 1001},
    )
    assert overassigned.status_code == 409
    future = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={"account_id": account["id"], "amount_minor": 5000, "occurred_on": "2099-01-01"},
    )
    assert future.status_code == 422

    tracking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Tracking", "account_type": "tracking", "is_on_budget": False},
    ).json()
    categorized_tracking = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": tracking["id"],
            "category_id": category["id"],
            "amount_minor": -100,
            "occurred_on": "2026-09-04",
        },
    )
    assert categorized_tracking.status_code == 422
