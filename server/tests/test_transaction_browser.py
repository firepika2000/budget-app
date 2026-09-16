from datetime import date, datetime, timezone

from sqlalchemy import event, insert

from app.models import Household, Membership, Transaction, User
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


def test_transaction_browser_keyset_cursor_does_not_duplicate_after_newer_insert(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    oldest = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-100, occurred_on="2026-09-01",
    )
    middle = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-200, occurred_on="2026-09-02",
    )
    first = _search(client, owner_token, budget["id"], "?limit=1&sort=date_desc")
    assert [row["id"] for row in first["items"]] == [middle["id"]]

    record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-300, occurred_on="2026-09-03",
    )
    second = _search(
        client, owner_token, budget["id"],
        f"?limit=1&sort=date_desc&cursor={first['next_cursor']}",
    )
    assert [row["id"] for row in second["items"]] == [oldest["id"]]


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


def test_transaction_browser_pages_in_sql_without_hydrating_the_budget(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        db.execute(insert(Transaction), [
            {
                "id": f"scale-{index:05d}",
                "budget_id": budget["id"],
                "account_id": account["id"],
                "category_id": groceries["id"],
                "amount_minor": -(index + 1),
                "occurred_on": date(2026, 9, 1),
                "created_at": datetime(2026, 9, 1, 12, 0, tzinfo=timezone.utc),
                "payee_name": f"Merchant {index:05d}",
                "memo": "scale characterization",
                "created_by_user_id": owner_id,
                "tags": ["scale"],
                "attachment_metadata": [],
            }
            for index in range(3_000)
        ])
        db.commit()

    loaded: list[str] = []

    def capture_load(target, _context):
        if target.budget_id == budget["id"]:
            loaded.append(target.id)

    event.listen(Transaction, "load", capture_load)
    try:
        first = _search(
            client, owner_token, budget["id"],
            "?limit=25&sort=amount_asc&tag=scale",
        )
    finally:
        event.remove(Transaction, "load", capture_load)

    assert first["total_count"] == 3_000
    assert len(first["items"]) == 25
    assert first["next_cursor"] is not None
    assert len(loaded) <= 26  # limit + one look-ahead row, never all 3,000

    second = _search(
        client, owner_token, budget["id"],
        f"?limit=25&sort=amount_asc&tag=scale&cursor={first['next_cursor']}",
    )
    first_ids = {row["id"] for row in first["items"]}
    second_ids = {row["id"] for row in second["items"]}
    assert len(second["items"]) == 25
    assert first_ids.isdisjoint(second_ids)
    assert [row["amount_minor"] for row in first["items"] + second["items"]] == sorted(
        row["amount_minor"] for row in first["items"] + second["items"]
    )


def test_transaction_browser_tag_filter_matches_complete_tags_only(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    exact = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-100, tags=["food"],
    )
    record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-200, tags=["foodie"],
    )
    result = _search(client, owner_token, budget["id"], "?tag=food")
    assert [row["id"] for row in result["items"]] == [exact["id"]]


def test_transaction_browser_filters_posted_voided_and_reversal_lifecycle(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    original = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-500,
    )
    posted = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=groceries["id"], amount_minor=-700,
    )
    voided = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/void",
        headers=auth(owner_token), json={"reason": "Browser lifecycle test"},
    )
    assert voided.status_code == 201, voided.text
    reversal = voided.json()

    assert [row["id"] for row in _search(
        client, owner_token, budget["id"], "?lifecycle_status=posted",
    )["items"]] == [posted["id"]]
    assert [row["id"] for row in _search(
        client, owner_token, budget["id"], "?lifecycle_status=voided",
    )["items"]] == [original["id"]]
    assert [row["id"] for row in _search(
        client, owner_token, budget["id"], "?lifecycle_status=reversal",
    )["items"]] == [reversal["id"]]
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/search?lifecycle_status=deleted",
        headers=auth(owner_token),
    ).status_code == 422
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/search?cursor=not-a-real-cursor",
        headers=auth(owner_token),
    ).status_code == 422
