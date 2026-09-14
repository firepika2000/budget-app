from datetime import date, timedelta

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child, configure_child


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


def test_same_owner_credential_can_post_actual_and_create_money_neutral_schedule(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    actual_url = f"/api/v1/budgets/{budget['id']}/transactions"
    schedule_url = f"/api/v1/budgets/{budget['id']}/scheduled-transactions"

    actual = client.post(actual_url, headers=auth(owner_token), json=transaction_body(account["id"], category["id"], date.today().isoformat()))
    assert actual.status_code == 201, actual.text
    balance_before = client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
    month = date.today().replace(day=1).isoformat()
    summary_before = client.get(f"/api/v1/budgets/{budget['id']}/months/{month}", headers=auth(owner_token)).json()

    body = {
        "account_id": account["id"], "category_id": category["id"], "name": "Scheduled Test",
        "amount_minor": -7500, "next_date": (date.today() + timedelta(days=1)).isoformat(),
        "recurrence_unit": "once", "interval_count": 1,
    }
    scheduled = client.post(schedule_url, headers=auth(owner_token), json=body)
    assert scheduled.status_code == 201, scheduled.text
    assert client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json() == balance_before
    assert client.get(f"/api/v1/budgets/{budget['id']}/months/{month}", headers=auth(owner_token)).json() == summary_before
    listed = client.get(schedule_url, headers=auth(owner_token)).json()
    assert scheduled.json()["id"] in {item["id"] for item in listed}
    forecast = client.get(f"/api/v1/budgets/{budget['id']}/forecast?through={(date.today() + timedelta(days=2)).isoformat()}", headers=auth(owner_token)).json()
    assert scheduled.json()["id"] in {item["scheduled_transaction_id"] for item in forecast["occurrences"]}

    member_id, member_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], member_id, account["id"], category["id"])
    forbidden = client.post(schedule_url, headers=auth(member_token), json=body)
    assert forbidden.status_code == 403
    invalid = client.post(schedule_url, headers={"Authorization": "Bearer invalid"}, json=body)
    assert invalid.status_code == 401
