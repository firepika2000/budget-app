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
    assert change["changes"] == [
        {"field": "amount_minor", "value_kind": "money_minor", "before_value": "-1200", "after_value": "-1350"},
        {"field": "is_cleared", "value_kind": "state", "before_value": "Uncleared", "after_value": "Cleared"},
        {"field": "memo", "value_kind": "text", "before_value": "", "after_value": "Receipt"},
    ]
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


def test_transaction_history_redacts_a_previously_hidden_category_value(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, private_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Delegated", "Allowance")
    transaction = record(client, owner_token, budget["id"], account_id=account["id"],
                         category_id=private_category["id"], amount_minor=-500, payee_name="Secret Clinic")
    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}",
        headers=auth(owner_token),
        json={"account_id": account["id"], "category_id": visible_category["id"],
              "amount_minor": -500, "occurred_on": transaction["occurred_on"],
              "payee_name": "Grocery Store", "memo": "Visible memo", "is_cleared": False},
    )
    assert updated.status_code == 200, updated.text
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, account["id"], visible_category["id"])

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}/history",
        headers=auth(child_token),
    )
    assert response.status_code == 200, response.text
    category_change = next(item for item in response.json()[0]["changes"] if item["field"] == "category_id")
    assert category_change == {
        "field": "category_id", "value_kind": "restricted",
        "before_value": "Private or unavailable", "after_value": "Delegated · Allowance",
    }
    assert private_category["id"] not in response.text
    assert "Secret Clinic" not in response.text
    assert any(item["field"] == "payee_name" and item["before_value"] == "Private or unavailable"
               for item in response.json()[0]["changes"])
