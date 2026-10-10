from app.models import CreditCardReserveEvent, TransactionChange
from app.models import Transaction, WorkspaceCommandReceipt
from uuid import uuid4
import pytest

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


def test_identified_duplicate_retries_preserve_one_posting_and_current_state(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"],
                      category_id=category["id"], amount_minor=-9007199254740993,
                      payee_name="Original", memo="keep", tags=["keep"], flag="orange")
    path = f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/duplicate"
    body = {"occurred_on": "2026-09-05", "expected_revision": original["revision"], "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201, first.text
    duplicate = first.json()
    assert duplicate["amount_minor"] == original["amount_minor"]
    assert duplicate["payee_id"] == original["payee_id"]
    assert duplicate["memo"] == "keep" and duplicate["tags"] == ["keep"] and duplicate["flag"] == "orange"
    with session_factory() as db:
        db.get(Transaction, original["id"]).memo = "source later changed"
        db.get(Transaction, duplicate["id"]).is_cleared = True
        changes = db.query(TransactionChange).count()
        db.commit()
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert retry.status_code == 201 and retry.json()["id"] == duplicate["id"]
    assert retry.json()["is_cleared"] is True
    assert client.post(path, headers=auth(owner_token), json={**body, "occurred_on": "2026-09-06"}).status_code == 409
    assert client.post(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 2
        assert db.query(TransactionChange).count() == changes
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_duplicate").count() == 1


@pytest.mark.parametrize("revision", [None, "invalid", "v1:" + "0" * 64])
def test_identified_duplicate_requires_current_observation(client, owner_token, session_factory, revision):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    response = client.post(f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/duplicate",
        headers=auth(owner_token), json={"occurred_on": "2026-09-05", "expected_revision": revision, "mutation_operation_id": str(uuid4())})
    assert response.status_code == (409 if revision and revision.startswith("v1:") else 422), response.text
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 1
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_duplicate").count() == 0


@pytest.mark.parametrize("restriction", ["account", "category", "capability"])
def test_duplicate_receipt_rechecks_current_scope(client, owner_token, session_factory, restriction):
    from .test_budgeting_api import add_member
    from app.models import User
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["create_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    path = f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/duplicate"
    body = {"occurred_on": "2026-09-05", "expected_revision": original["revision"], "mutation_operation_id": str(uuid4())}
    assert client.post(path, headers=auth(token), json=body).status_code == 201
    if restriction == "account": access.update(restrict_accounts=True, account_ids=[])
    elif restriction == "category": access.update(restrict_categories=True, category_ids=[])
    else: access["capabilities"].remove("create_transaction")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    denied = client.post(path, headers=auth(token), json=body)
    assert denied.status_code == (403 if restriction == "capability" else 404), denied.text
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 2


def test_duplicate_provenance_failure_rolls_back_posting(client, owner_token, session_factory, monkeypatch):
    import app.budgeting_routes as routes
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    original_recorder = routes.record_transaction_change
    def fail_duplicate(db, transaction, user, action, **kwargs):
        if action == "duplicated": raise RuntimeError("Injected provenance failure")
        return original_recorder(db, transaction, user, action, **kwargs)
    monkeypatch.setattr(routes, "record_transaction_change", fail_duplicate)
    with pytest.raises(RuntimeError, match="Injected provenance failure"):
        client.post(f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/duplicate", headers=auth(owner_token),
            json={"occurred_on": "2026-09-05", "expected_revision": original["revision"], "mutation_operation_id": str(uuid4())})
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 1
        assert db.query(TransactionChange).filter_by(action="duplicated").count() == 0
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_duplicate").count() == 0


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
