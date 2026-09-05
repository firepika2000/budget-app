from .conftest import auth
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def test_group_lifecycle_ordering_and_safe_delete(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}"
    groups = client.get(f"{path}/category-groups", headers=auth(owner_token)).json()
    group = groups[0]
    updated = client.put(f"{path}/category-groups/{group['id']}", headers=auth(owner_token), json={"name": "Essentials", "sort_order": 2, "is_archived": True})
    assert updated.status_code == 200
    assert (updated.json()["name"], updated.json()["sort_order"], updated.json()["is_archived"]) == ("Essentials", 2, True)
    assert client.delete(f"{path}/category-groups/{group['id']}", headers=auth(owner_token)).status_code == 409

    category_update = {"group_id": group["id"], "name": "Groceries", "sort_order": 3, "is_archived": True}
    assert client.put(f"{path}/categories/{category['id']}", headers=auth(owner_token), json=category_update).status_code == 200
    category_update["is_archived"] = False
    restored = client.put(f"{path}/categories/{category['id']}", headers=auth(owner_token), json=category_update)
    assert restored.status_code == 200 and restored.json()["sort_order"] == 3 and not restored.json()["is_archived"]

    empty = client.post(f"{path}/category-groups", headers=auth(owner_token), json={"name": "Temporary", "sort_order": 99}).json()
    assert client.delete(f"{path}/category-groups/{empty['id']}", headers=auth(owner_token)).status_code == 204


def test_category_delete_only_when_history_free_and_restricted_cannot_manage(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}"
    viewer = add_member(session_factory, client, "view", budget["id"])
    group = client.get(f"{path}/category-groups", headers=auth(owner_token)).json()[0]
    denied = client.put(f"{path}/category-groups/{group['id']}", headers=auth(viewer), json={"name": "No", "sort_order": 0, "is_archived": False})
    assert denied.status_code == 403

    disposable = client.post(f"{path}/categories", headers=auth(owner_token), json={"group_id": group["id"], "name": "Disposable", "sort_order": 7}).json()
    assert client.delete(f"{path}/categories/{disposable['id']}", headers=auth(owner_token)).status_code == 204

    client.post(f"{path}/transactions", headers=auth(owner_token), json={"account_id": account["id"], "category_id": category["id"], "amount_minor": -100, "occurred_on": "2026-09-01", "payee_name": "History"})
    refused = client.delete(f"{path}/categories/{category['id']}", headers=auth(owner_token))
    assert refused.status_code == 409
    assert "Archive" in refused.json()["detail"]
