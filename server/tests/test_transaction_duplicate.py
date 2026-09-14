from app.models import CreditCardReserveEvent, TransactionChange

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card


def _duplicate(client, token, budget_id, transaction_id, occurred_on="2026-09-05"):
    return client.post(
        f"/api/v1/budgets/{budget_id}/transactions/{transaction_id}/duplicate",
        headers=auth(token), json={"occurred_on": occurred_on},
    )


def test_duplicate_split_posts_exactly_once_and_records_provenance(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    original = record(
        client, owner_token, budget["id"], account_id=account["id"], amount_minor=-1500,
        payee_name="Market", memo="split", is_cleared=True, flag="blue", tags=["weekly"],
        splits=[
            {"category_id": groceries["id"], "amount_minor": -1000},
            {"category_id": dining["id"], "amount_minor": -500},
        ],
    )
    response = _duplicate(client, owner_token, budget["id"], original["id"])
    assert response.status_code == 201, response.text
    duplicate = response.json()
    assert duplicate["id"] != original["id"]
    assert duplicate["occurred_on"] == "2026-09-05"
    assert duplicate["is_cleared"] is False
    assert duplicate["attachment_metadata"] == []
    assert sum(split["amount_minor"] for split in duplicate["splits"]) == -1500

    summary = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()
    rows = {item["category_id"]: item for item in summary["categories"]}
    assert rows[groceries["id"]]["activity_minor"] == -2000
    assert rows[dining["id"]]["activity_minor"] == -1000
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(transaction_id=original["id"], action="created").count() == 1
        change = db.query(TransactionChange).filter_by(transaction_id=duplicate["id"], action="duplicated").one()
        assert original["id"] not in (change.before_json or "")  # snapshots contain values, not fragile IDs
        assert change.actor_user_id == duplicate["created_by_user_id"]


def test_duplicate_funded_card_purchase_rebuilds_reserve_once(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 50000},
    )
    original = record(
        client, owner_token, budget["id"], account_id=card["id"],
        category_id=groceries["id"], amount_minor=-10000,
    )
    assert _duplicate(client, owner_token, budget["id"], original["id"]).status_code == 201
    with session_factory() as db:
        events = db.query(CreditCardReserveEvent).filter_by(credit_account_id=card["id"]).all()
        assert len(events) == 2
        assert sum(event.amount_minor for event in events) == 20000


def test_duplicate_rejects_system_linked_transactions(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 5000},
    ).json()
    starting = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()[0]
    denied = _duplicate(client, owner_token, budget["id"], starting["id"])
    assert denied.status_code == 409
    assert len(client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()) == 1
