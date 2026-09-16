from app.models import Household, Membership, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure


def _search(client, token, budget_id, query=""):
    response = client.get(
        f"/api/v1/budgets/{budget_id}/transactions/search{query}", headers=auth(token)
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_transaction_browser_filters_sorts_and_paginates_without_mutation(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    first = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-1200, occurred_on="2026-09-01",
        payee_name="Neighborhood Market", memo="weekly fruit", is_cleared=True,
        flag="red", tags=["food", "weekly"],
    )
    second = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=dining["id"], amount_minor=-2500, occurred_on="2026-09-02",
        payee_name="Corner Cafe", memo="lunch", flag="blue", tags=["food"],
    )
    refund = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=300, occurred_on="2026-09-03",
        payee_name="Neighborhood Market", memo="refund",
    )

    page_one = _search(client, owner_token, budget["id"], "?limit=2&sort=date_asc")
    assert [item["id"] for item in page_one["items"]] == [first["id"], second["id"]]
    assert page_one["total_count"] == 3
    assert page_one["next_cursor"]
    page_two = _search(
        client, owner_token, budget["id"],
        f"?limit=2&sort=date_asc&cursor={page_one['next_cursor']}",
    )
    assert [item["id"] for item in page_two["items"]] == [refund["id"]]
    assert page_two["next_cursor"] is None

    assert [item["id"] for item in _search(client, owner_token, budget["id"], "?q=FRUIT")["items"]] == [first["id"]]
    assert {item["id"] for item in _search(client, owner_token, budget["id"], "?tag=food")["items"]} == {first["id"], second["id"]}
    assert [item["id"] for item in _search(client, owner_token, budget["id"], "?transaction_type=refund")["items"]] == [refund["id"]]
    assert [item["id"] for item in _search(client, owner_token, budget["id"], f"?category_id={dining['id']}")["items"]] == [second["id"]]
    assert [item["id"] for item in _search(client, owner_token, budget["id"], "?cleared=true")["items"]] == [first["id"]]

    # Querying is observational only.
    assert len(client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()) == 3


def test_transaction_browser_filters_split_categories(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    split = record(
        client, owner_token, budget["id"], account_id=account["id"], amount_minor=-1500,
        splits=[
            {"category_id": groceries["id"], "amount_minor": -1000},
            {"category_id": dining["id"], "amount_minor": -500},
        ],
    )
    result = _search(client, owner_token, budget["id"], f"?category_id={dining['id']}")
    assert [item["id"] for item in result["items"]] == [split["id"]]


def test_restricted_search_never_leaks_hidden_rows_or_counts(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, private_category = create_budget_structure(client, owner_token, budget["id"])
    shared_category = add_category(client, owner_token, budget["id"], "Shared", "Allowance")
    private = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=private_category["id"], amount_minor=-9900,
        payee_name="Secret Merchant", memo="private detail", tags=["secret"],
    )
    visible = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=shared_category["id"], amount_minor=-500,
        payee_name="Shared Shop",
    )
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="browser@example.com", display_name="Browser", password_hash=hash_password("browser password long enough"))
        db.add(member)
        db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="child"))
        db.commit()
        member_id = member.id
    token = create_access_token(member_id, client.app.state.settings)
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token),
        json={"user_id": member_id, "permission": "view"},
    ).status_code == 200
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token),
        json={
            "capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions"],
            "restrict_accounts": True, "account_ids": [account["id"]],
            "restrict_categories": True, "category_ids": [shared_category["id"]],
        },
    ).status_code == 200

    all_visible = _search(client, token, budget["id"])
    assert all_visible["total_count"] == 1
    assert [item["id"] for item in all_visible["items"]] == [visible["id"]]
    for query in ["?q=secret", f"?category_id={private_category['id']}", "?tag=secret"]:
        hidden = _search(client, token, budget["id"], query)
        assert hidden == {"items": [], "next_cursor": None, "total_count": 0}
        assert private["id"] not in str(hidden)

    hidden_payee = client.get(
        f"/api/v1/budgets/{budget['id']}/payees/search?q=secret", headers=auth(token)
    )
    assert hidden_payee.status_code == 200
    assert hidden_payee.json() == {"items": [], "next_cursor": None}
    visible_payee = client.get(
        f"/api/v1/budgets/{budget['id']}/payees/search?q=shared", headers=auth(token)
    ).json()
    assert [item["display_name"] for item in visible_payee["items"]] == ["Shared Shop"]


def test_transaction_browser_rejects_invalid_range_and_cursor(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/search?start_date=2026-09-05&end_date=2026-09-01",
        headers=auth(owner_token),
    ).status_code == 422
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/search?cursor=not-a-real-cursor",
        headers=auth(owner_token),
    ).status_code == 422
