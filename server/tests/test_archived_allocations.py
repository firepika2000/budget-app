import pytest

from .conftest import auth
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure


@pytest.mark.parametrize("archive_parent", [False, True])
def test_archived_category_or_group_cannot_receive_or_move_allocations(
    client, owner_token, session_factory, archive_parent
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    other = add_category(client, owner_token, budget["id"], "Other group", "Other category")
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    root = f"/api/v1/budgets/{budget['id']}"
    headers = auth(owner_token)
    for item in (category, other):
        assert client.put(f"{root}/categories/{item['id']}/assignment", headers=headers,
                          json={"month": "2026-09-01", "assigned_minor": 30000}).status_code == 200
    history_before = client.get(f"{root}/allocations", headers=headers).json()
    balance_before = client.get(f"{root}/accounts/{account['id']}/balance", headers=headers).json()
    if archive_parent:
        target = next(g for g in client.get(f"{root}/category-groups", headers=headers).json()
                      if g["id"] == category["group_id"])
        url = f"{root}/category-groups/{target['id']}"
        payload = {"name": target["name"], "sort_order": target["sort_order"]}
    else:
        url = f"{root}/categories/{category['id']}"
        payload = {"name": category["name"], "group_id": category["group_id"], "sort_order": category["sort_order"]}
    assert client.put(url, headers=headers, json={**payload, "is_archived": True}).status_code == 200
    for amount in (40000, 20000):
        attempted = client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
                               json={"month": "2026-09-01", "assigned_minor": amount})
        assert attempted.status_code == 422, attempted.text
    for source, destination in ((category, other), (other, category)):
        moved = client.post(f"{root}/allocation-transfers", headers=headers, json={
            "source_category_id": source["id"], "destination_category_id": destination["id"],
            "amount_minor": 1000, "occurred_on": "2026-09-01",
        })
        assert moved.status_code == 422, moved.text
    assert client.get(f"{root}/allocations", headers=headers).json() == history_before
    assert client.get(f"{root}/accounts/{account['id']}/balance", headers=headers).json() == balance_before
    assert client.put(url, headers=headers, json={**payload, "is_archived": False}).status_code == 200
    restored = client.get(f"{root}/months/2026-09-01", headers=headers).json()
    assert restored["ready_to_assign_minor"] == 40000
    assert next(row for row in restored["categories"] if row["category_id"] == category["id"])["available_minor"] == 30000
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
                      json={"month": "2026-09-01", "assigned_minor": 40000}).status_code == 200
