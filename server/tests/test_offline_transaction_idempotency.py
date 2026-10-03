from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def test_offline_transaction_replay_creates_exactly_one_financial_observation(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    body = {
        "account_id": account["id"],
        "category_id": category["id"],
        "amount_minor": -1234,
        "occurred_on": "2026-01-15",
        "payee_name": "Offline Market",
        "memo": "queued once",
        "client_operation_id": "ddef4659-63cf-42cf-9e3d-91cbc9b471ca",
        "tags": ["offline"],
    }

    first = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json=body,
    )
    replay = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json=body,
    )
    assert first.status_code == 201, first.text
    assert replay.status_code == 201, replay.text
    assert replay.json()["id"] == first.json()["id"]

    rows = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
    )
    assert rows.status_code == 200, rows.text
    matching = [row for row in rows.json() if row["memo"] == "queued once"]
    assert len(matching) == 1
    balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    )
    assert balance.status_code == 200, balance.text
    assert balance.json()["working_balance_minor"] == -1234


def test_idempotency_identity_is_scoped_to_actor_and_budget(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    operation_id = "9c9168e8-e981-4272-9021-4ba8665b4564"
    body = {
        "account_id": account["id"], "category_id": category["id"],
        "amount_minor": -100, "occurred_on": "2026-01-15",
        "payee_name": "Scoped", "client_operation_id": operation_id,
    }
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json=body,
    ).status_code == 201

    second_budget = create_budget(client, owner_token, session_factory)
    second_account, second_category = create_budget_structure(
        client, owner_token, second_budget["id"]
    )
    body["account_id"] = second_account["id"]
    body["category_id"] = second_category["id"]
    response = client.post(
        f"/api/v1/budgets/{second_budget['id']}/transactions",
        headers=auth(owner_token), json=body,
    )
    assert response.status_code == 201, response.text
