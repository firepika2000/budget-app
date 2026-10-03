from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure


def test_transaction_list_exposes_authorized_creator_and_latest_editor(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=category["id"], amount_minor=-200, memo="Original",
    )
    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}",
        headers=auth(owner_token),
        json={
            "account_id": account["id"], "category_id": category["id"],
            "amount_minor": -200, "occurred_on": transaction["occurred_on"],
            "payee_name": transaction["payee_name"], "memo": "Corrected",
        },
    )
    assert updated.status_code == 200, updated.text

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    row = next(item for item in response.json() if item["id"] == transaction["id"])
    assert row["created_by_display_name"] == "Owner"
    assert row["last_modified_by_user_id"] == row["created_by_user_id"]
    assert row["last_modified_by_display_name"] == "Owner"
    assert row["last_modified_at"] is not None
    assert row["memo"] == "Corrected"
