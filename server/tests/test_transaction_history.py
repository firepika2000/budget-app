from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child, configure_child


def test_transaction_history_is_bounded_attributed_and_snapshot_private(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"],
                         category_id=category["id"], amount_minor=-1200, payee_name="Market")
    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}",
        headers=auth(owner_token),
        json={"account_id": account["id"], "category_id": category["id"], "amount_minor": -1350,
              "occurred_on": transaction["occurred_on"], "payee_name": "Market", "memo": "Receipt",
              "is_cleared": True},
    )
    assert updated.status_code == 200, updated.text

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}/history?limit=1&offset=0",
        headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    assert len(response.json()) == 1
    change = response.json()[0]
    assert change["action"] == "updated"
    assert change["actor_display_name"] == "Owner"
    assert change["changed_fields"] == ["amount_minor", "is_cleared", "memo"]
    assert "before_json" not in change and "after_json" not in change


def test_transaction_history_rechecks_current_resource_scope(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, private_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Delegated", "Allowance")
    hidden = record(client, owner_token, budget["id"], account_id=account["id"],
                    category_id=private_category["id"], amount_minor=-500, payee_name="Private")
    visible = record(client, owner_token, budget["id"], account_id=account["id"],
                     category_id=visible_category["id"], amount_minor=-200, payee_name="Visible")
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, account["id"], visible_category["id"])

    base = f"/api/v1/budgets/{budget['id']}/transactions"
    assert client.get(f"{base}/{hidden['id']}/history", headers=auth(child_token)).status_code == 404
    allowed = client.get(f"{base}/{visible['id']}/history", headers=auth(child_token))
    assert allowed.status_code == 200, allowed.text
    assert [item["action"] for item in allowed.json()] == ["created"]
