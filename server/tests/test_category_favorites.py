from .conftest import auth
from .test_advanced_ledger import add_category
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child, configure_child


def test_favorites_are_personal_ordered_metadata_and_money_neutral(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    _, groceries = create_budget_structure(client, owner_token, budget["id"])
    fuel = add_category(client, owner_token, budget["id"], "Needs", "Fuel")
    path = f"/api/v1/budgets/{budget['id']}"
    before = client.get(f"{path}/months/2026-09-01", headers=auth(owner_token)).json()

    first = client.put(
        f"{path}/categories/{groceries['id']}/favorite",
        headers=auth(owner_token), json={"sort_order": 20},
    )
    second = client.put(
        f"{path}/categories/{fuel['id']}/favorite",
        headers=auth(owner_token), json={"sort_order": 10},
    )
    assert first.status_code == second.status_code == 200
    assert first.json()["is_favorite"] is True
    assert first.json()["favorite_sort_order"] == 20

    listed = client.get(f"{path}/categories", headers=auth(owner_token)).json()
    favorites = sorted(
        (row for row in listed if row["is_favorite"]),
        key=lambda row: (row["favorite_sort_order"], row["name"]),
    )
    assert [row["name"] for row in favorites] == ["Fuel", "Groceries"]
    assert client.get(f"{path}/months/2026-09-01", headers=auth(owner_token)).json() == before

    assert client.delete(
        f"{path}/categories/{groceries['id']}/favorite", headers=auth(owner_token)
    ).status_code == 204
    after = {row["id"]: row for row in client.get(
        f"{path}/categories", headers=auth(owner_token)
    ).json()}
    assert after[groceries["id"]]["is_favorite"] is False
    assert after[groceries["id"]]["favorite_sort_order"] is None


def test_restricted_member_can_only_favorite_visible_categories_without_leakage(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, hidden = create_budget_structure(client, owner_token, budget["id"])
    visible = add_category(client, owner_token, budget["id"], "Delegated", "Visible")
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, account["id"], visible["id"])
    path = f"/api/v1/budgets/{budget['id']}"

    hidden_result = client.put(
        f"{path}/categories/{hidden['id']}/favorite",
        headers=auth(child_token), json={"sort_order": 0},
    )
    assert hidden_result.status_code == 404
    assert hidden["id"] not in hidden_result.text

    visible_result = client.put(
        f"{path}/categories/{visible['id']}/favorite",
        headers=auth(child_token), json={"sort_order": 3},
    )
    assert visible_result.status_code == 200
    child_rows = client.get(f"{path}/categories", headers=auth(child_token)).json()
    assert [(row["id"], row["is_favorite"]) for row in child_rows] == [(visible["id"], True)]

    owner_rows = {row["id"]: row for row in client.get(
        f"{path}/categories", headers=auth(owner_token)
    ).json()}
    assert owner_rows[visible["id"]]["is_favorite"] is False

    assert client.delete(
        f"{path}/categories/{hidden['id']}/favorite", headers=auth(child_token)
    ).status_code == 404
