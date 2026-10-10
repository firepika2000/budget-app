from uuid import uuid4
import pytest

from app.models import Transaction, TransactionChange, User, WorkspaceCommandReceipt

from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def test_identified_edit_acknowledges_once_without_reverting_later_edits(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{row['id']}"
    body = {key: row[key] for key in ["account_id", "category_id", "amount_minor", "occurred_on", "payee_name", "memo", "is_cleared", "flag", "tags"]}
    body.update(amount_minor=-200, memo="Accepted edit", expected_revision=row["revision"], mutation_operation_id=str(uuid4()))
    first = client.put(path, headers=auth(owner_token), json=body)
    assert first.status_code == 200, first.text
    with session_factory() as db:
        history = db.query(TransactionChange).filter_by(transaction_id=row["id"]).count()
    replay = client.put(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 200, replay.text
    assert replay.json() == first.json()
    assert client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()["working_balance_minor"] == -200
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(transaction_id=row["id"]).count() == history
        assert db.query(WorkspaceCommandReceipt).count() == 1
    later = {**body, "memo": "Later edit", "expected_revision": first.json()["revision"]}
    later.pop("mutation_operation_id")
    assert client.put(path, headers=auth(owner_token), json=later).status_code == 200
    replay = client.put(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 200 and replay.json()["memo"] == "Later edit"
    assert client.put(path, headers=auth(owner_token), json={**body, "memo": "Wrong identity reuse"}).status_code == 409
    with session_factory() as db:
        db.get(Transaction, row["id"]).is_reconciled = True
        db.commit()
        history = db.query(TransactionChange).filter_by(transaction_id=row["id"]).count()
    replay = client.put(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 200 and replay.json()["is_reconciled"] is True
    assert client.put(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(transaction_id=row["id"]).count() == history


def test_identified_edit_requires_observation_and_rejects_stale_without_receipt(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{row['id']}"
    body = {"account_id": account["id"], "category_id": category["id"], "amount_minor": -100,
            "occurred_on": row["occurred_on"], "payee_name": row["payee_name"], "memo": "Draft",
            "mutation_operation_id": str(uuid4())}
    assert client.put(path, headers=auth(owner_token), json=body).status_code == 422
    assert client.put(path, headers=auth(owner_token), json={**body, "expected_revision": "v1:" + "0" * 64}).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.get(Transaction, row["id"]).memo != "Draft"


@pytest.mark.parametrize("restriction", ["account", "category", "capability"])
def test_edit_receipt_does_not_grant_authority_after_revocation(client, owner_token, session_factory, restriction):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["create_transaction", "edit_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    row = record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{row['id']}"
    body = {"account_id": account["id"], "category_id": category["id"], "amount_minor": -100,
            "occurred_on": row["occurred_on"], "payee_name": row["payee_name"], "memo": "Private edit",
            "mutation_operation_id": str(uuid4()), "expected_revision": row["revision"]}
    assert client.put(path, headers=auth(token), json=body).status_code == 200
    if restriction == "capability":
        access["capabilities"].remove("edit_transaction")
    else:
        access["restrict_accounts" if restriction == "account" else "restrict_categories"] = True
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    with session_factory() as db:
        history = db.query(TransactionChange).count()
    response = client.put(path, headers=auth(token), json=body)
    assert response.status_code == (403 if restriction == "capability" else 404), response.text
    assert "Private edit" not in response.text
    with session_factory() as db:
        assert db.query(TransactionChange).count() == history
        assert db.query(WorkspaceCommandReceipt).count() == 1
