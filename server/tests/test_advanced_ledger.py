from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def add_category(client, owner_token, budget_id, group_name, category_name):
    group = client.post(
        f"/api/v1/budgets/{budget_id}/category-groups",
        headers=auth(owner_token),
        json={"name": group_name},
    ).json()
    response = client.post(
        f"/api/v1/budgets/{budget_id}/categories",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": category_name},
    )
    assert response.status_code == 201
    return response.json()


def record(client, token, budget_id, **values):
    body = {
        "occurred_on": "2026-09-04",
        "payee_name": "Test",
        **values,
    }
    response = client.post(
        f"/api/v1/budgets/{budget_id}/transactions",
        headers=auth(token),
        json=body,
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_split_activity_and_income_feed_month_summary(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=100000,
        is_cleared=True,
    )
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 40000},
    )
    split = record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=-15000,
        is_cleared=True,
        splits=[
            {"category_id": groceries["id"], "amount_minor": -10000},
            {"category_id": dining["id"], "amount_minor": -5000},
        ],
    )
    assert [item["amount_minor"] for item in split["splits"]] == [-10000, -5000]

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    )
    assert summary.status_code == 200
    data = summary.json()
    assert data["ready_to_assign_minor"] == 60000
    assert data["total_assigned_minor"] == 40000
    assert data["total_overspent_minor"] == 5000
    by_name = {item["name"]: item for item in data["categories"]}
    assert by_name["Groceries"]["available_minor"] == 30000
    assert by_name["Dining"]["available_minor"] == -5000


def test_transfer_is_balanced_and_does_not_create_income(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings_response = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings"},
    )
    savings = savings_response.json()
    transfer = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": savings["id"],
            "amount_minor": 25000,
            "occurred_on": "2026-09-04",
        },
    )
    assert transfer.status_code == 201
    data = transfer.json()
    assert data["source"]["amount_minor"] == -25000
    assert data["destination"]["amount_minor"] == 25000
    assert data["source"]["transfer_id"] == data["destination"]["transfer_id"]
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    assert summary["ready_to_assign_minor"] == 0


def test_reconciliation_requires_exact_cleared_balance(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=50000,
        is_cleared=True,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        category_id=category["id"],
        amount_minor=-1250,
        is_cleared=True,
    )

    mismatch = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": 48000, "through_date": "2026-09-30"},
    )
    assert mismatch.status_code == 409
    assert mismatch.json()["detail"]["cleared_balance_minor"] == 48750

    matched = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": 48750, "through_date": "2026-09-30"},
    )
    assert matched.status_code == 200
    assert matched.json()["reconciled_transaction_count"] == 2


def test_split_total_must_equal_transaction_total(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    response = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": account["id"],
            "amount_minor": -1000,
            "occurred_on": "2026-09-04",
            "splits": [{"category_id": category["id"], "amount_minor": -999}],
        },
    )
    assert response.status_code == 422


def test_ready_to_assign_excludes_tracking_cash_and_includes_uncategorized_outflow(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    tracking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Investment", "account_type": "tracking", "is_on_budget": False},
    ).json()
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=10000,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=-250,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=tracking["id"],
        amount_minor=999999,
    )
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    assert summary["ready_to_assign_minor"] == 9750
