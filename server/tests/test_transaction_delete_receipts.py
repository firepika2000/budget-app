from uuid import uuid4

import pytest

from app.models import Transaction, TransactionChange, WorkspaceCommandReceipt, User
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure, add_member


def reviewed_delete(client, token, factory, categorized=True):
    budget = create_budget(client, token, factory)
    account, category = create_budget_structure(client, token, budget["id"])
    transaction = record(client, token, budget["id"], account_id=account["id"],
        category_id=category["id"] if categorized else None, amount_minor=-9007199254740993)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}"
    request = {"headers": {**auth(token), "X-Transaction-Operation-ID": str(uuid4())},
               "params": {"expected_revision": transaction["revision"]}}
    return budget, account, category, transaction, path, request


def test_deletion_retry_acknowledges_once_and_preserves_other_transactions(client, owner_token, session_factory):
    budget, account, _, transaction, path, request = reviewed_delete(client, owner_token, session_factory)
    assert client.delete(path, **request).status_code == 204
    other = record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=100)
    assert client.delete(path, **request).status_code == 204
    assert client.delete(path, headers=auth(owner_token)).status_code == 404
    assert client.delete(path, headers=request["headers"], params={"expected_revision": "v1:" + "0" * 64}).status_code == 409
    with session_factory() as db:
        assert db.get(Transaction, transaction["id"]) is None
        assert db.get(Transaction, other["id"]).amount_minor == 100
        assert db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="deleted").count() == 1
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_delete").count() == 1


@pytest.mark.parametrize("revision", [None, "invalid", "v1:" + "0" * 64])
def test_deletion_requires_reviewed_revision(client, owner_token, session_factory, revision):
    _, _, _, transaction, path, request = reviewed_delete(client, owner_token, session_factory)
    response = client.delete(path, headers=request["headers"], params={} if revision is None else {"expected_revision": revision})
    assert response.status_code == (409 if revision and revision.startswith("v1:") else 422), response.text
    with session_factory() as db:
        assert db.get(Transaction, transaction["id"]) is not None
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_delete").count() == 0


@pytest.mark.parametrize("restriction", ["account", "category", "capability", "uncategorized"])
def test_deleted_receipt_rechecks_scope_and_ownership(client, owner_token, session_factory, restriction):
    budget, _, _, transaction, path, request = reviewed_delete(client, owner_token, session_factory, categorized=restriction != "uncategorized")
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
        db.get(Transaction, transaction["id"]).created_by_user_id = member
        db.commit()
        from app.schemas import TransactionResponse
        request["params"]["expected_revision"] = TransactionResponse.model_validate(db.get(Transaction, transaction["id"])).revision
    request["headers"].update(auth(token))
    access = {"capabilities": ["delete_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    assert client.delete(path, **request).status_code == 204
    if restriction == "account": access.update(restrict_accounts=True, account_ids=[])
    elif restriction in {"category", "uncategorized"}: access.update(restrict_categories=True, category_ids=[])
    else: access["capabilities"].remove("delete_transaction")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    denied = client.delete(path, **request)
    assert denied.status_code == (403 if restriction == "capability" else 404), denied.text


def test_deleted_receipt_requires_retained_authority_evidence(client, owner_token, session_factory):
    _, _, _, transaction, path, request = reviewed_delete(client, owner_token, session_factory)
    assert client.delete(path, **request).status_code == 204
    with session_factory() as db:
        db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="deleted").delete()
        db.commit()
    assert client.delete(path, **request).status_code == 409


@pytest.mark.parametrize("protection", ["reconciled", "voided", "reversal"])
def test_identified_deletion_keeps_lifecycle_protections(client, owner_token, session_factory, protection):
    _, _, _, transaction, path, request = reviewed_delete(client, owner_token, session_factory)
    with session_factory() as db:
        current = db.get(Transaction, transaction["id"])
        if protection == "reconciled": current.is_reconciled = True
        else: current.status = protection
        db.commit()
    assert client.delete(path, **request).status_code == 409
    with session_factory() as db:
        assert db.get(Transaction, transaction["id"]) is not None
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transaction_delete").count() == 0
