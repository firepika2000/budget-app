from .conftest import auth
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def test_category_names_are_normalized_unique_within_group_but_allowed_across_groups(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}"
    first_group = client.get(f"{path}/category-groups", headers=auth(owner_token)).json()[0]
    second_group = client.post(
        f"{path}/category-groups",
        headers=auth(owner_token),
        json={"name": "Savings Goals", "sort_order": 1},
    ).json()
    before_categories = client.get(f"{path}/categories", headers=auth(owner_token)).json()

    for duplicate_name in ("Groceries", "groceries", "  GROCERIES  "):
        rejected = client.post(
            f"{path}/categories",
            headers=auth(owner_token),
            json={"group_id": first_group["id"], "name": duplicate_name},
        )
        assert rejected.status_code == 409
        assert "already exists" in rejected.json()["detail"]
    assert client.get(f"{path}/categories", headers=auth(owner_token)).json() == before_categories

    cross_group = client.post(
        f"{path}/categories",
        headers=auth(owner_token),
        json={"group_id": second_group["id"], "name": " groceries "},
    )
    assert cross_group.status_code == 201
    assert cross_group.json()["name"] == "groceries"

    vacation = client.post(
        f"{path}/categories",
        headers=auth(owner_token),
        json={"group_id": second_group["id"], "name": "Vacation"},
    ).json()
    conflict = client.put(
        f"{path}/categories/{vacation['id']}",
        headers=auth(owner_token),
        json={"group_id": second_group["id"], "name": " GROCERIES ", "sort_order": 0, "is_archived": False},
    )
    assert conflict.status_code == 409

    own_normalized = client.put(
        f"{path}/categories/{category['id']}",
        headers=auth(owner_token),
        json={"group_id": first_group["id"], "name": " groceries ", "sort_order": 0, "is_archived": False},
    )
    assert own_normalized.status_code == 200
    assert own_normalized.json()["name"] == "groceries"


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


def test_archived_group_hides_its_categories_from_the_plan_but_preserves_history(client, owner_token, session_factory):
    from .test_advanced_ledger import record
    from .test_allocation_ledger import fund

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}"
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    assert client.put(f"{path}/categories/{category['id']}/assignment", headers=auth(owner_token),
                      json={"month": "2026-09-01", "assigned_minor": 40000}).status_code == 200

    def summary():
        return client.get(f"{path}/months/2026-09-01", headers=auth(owner_token)).json()

    before = summary()
    assert category["id"] in {r["category_id"] for r in before["categories"]}
    rta_before = before["ready_to_assign_minor"]

    group = client.get(f"{path}/category-groups", headers=auth(owner_token)).json()[0]
    body = {"name": group["name"], "sort_order": group["sort_order"], "is_archived": True}
    assert client.put(f"{path}/category-groups/{group['id']}", headers=auth(owner_token), json=body).status_code == 200

    after = summary()
    # Hidden from the plan once its group is archived (parity with the deterministic demo).
    assert category["id"] not in {r["category_id"] for r in after["categories"]}
    # Money preserved: RTA unchanged because allocations remain in the ledger.
    assert after["ready_to_assign_minor"] == rta_before
    # Still present for management, and the group is listed as archived.
    assert category["id"] in {c["id"] for c in client.get(f"{path}/categories", headers=auth(owner_token)).json()}
    groups = {g["id"]: g for g in client.get(f"{path}/category-groups", headers=auth(owner_token)).json()}
    assert groups[group["id"]]["is_archived"] is True

    # Restoring the group brings its categories back to the plan.
    body["is_archived"] = False
    assert client.put(f"{path}/category-groups/{group['id']}", headers=auth(owner_token), json=body).status_code == 200
    assert category["id"] in {r["category_id"] for r in summary()["categories"]}
