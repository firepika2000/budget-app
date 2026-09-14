from datetime import date, timedelta

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def transaction_body(account_id, category_id, occurred_on):
    return {
        "account_id": account_id,
        "category_id": category_id,
        "amount_minor": -1000,
        "occurred_on": occurred_on,
        "payee_name": "Routing proof",
    }


def test_actual_endpoint_distinguishes_current_future_and_authentication(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    endpoint = f"/api/v1/budgets/{budget['id']}/transactions"

    current = client.post(endpoint, headers=auth(owner_token), json=transaction_body(account["id"], category["id"], date.today().isoformat()))
    assert current.status_code == 201, current.text

    future = client.post(endpoint, headers=auth(owner_token), json=transaction_body(account["id"], category["id"], (date.today() + timedelta(days=1)).isoformat()))
    assert future.status_code == 422
    assert future.json()["detail"] == "Future transactions belong in the planning layer"

    unauthenticated_current = client.post(endpoint, json=transaction_body(account["id"], category["id"], date.today().isoformat()))
    unauthenticated_future = client.post(endpoint, json=transaction_body(account["id"], category["id"], (date.today() + timedelta(days=1)).isoformat()))
    assert unauthenticated_current.status_code == 401
    assert unauthenticated_future.status_code == 401
    assert unauthenticated_future.json()["detail"] == "Invalid or expired credentials"
