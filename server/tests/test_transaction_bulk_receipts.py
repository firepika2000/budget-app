from uuid import uuid4
import pytest

from app.models import Transaction, TransactionChange, User, WorkspaceCommandReceipt
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


@pytest.mark.parametrize("action,values", [
    ("set_cleared", {"cleared": True}), ("set_flag", {"flag": "orange"}),
    ("add_tags", {"tags": ["new"]}), ("remove_tags", {"tags": ["old"]}),
])
def test_identified_bulk_retry_acknowledges_without_reapplying(client, owner_token, session_factory, action, values):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    rows = [record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                   amount_minor=-100, tags=["old"], memo="Unchanged") for _ in range(2)]
    path = f"/api/v1/budgets/{budget['id']}/transactions/bulk"
    body = {"transaction_ids": [r["id"] for r in rows], "action": action, **values,
            "expected_revisions": {r["id"]: r["revision"] for r in rows}, "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 200, first.text
    with session_factory() as db:
        count = db.query(TransactionChange).count()
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert retry.status_code == 200 and retry.json() == first.json()
    with session_factory() as db:
        assert db.query(TransactionChange).count() == count
        assert db.query(WorkspaceCommandReceipt).count() == 1
        for row in rows:
            db.get(Transaction, row["id"]).memo = "Later value"
            db.get(Transaction, row["id"]).is_reconciled = True
        db.commit()
    acknowledged = client.post(path, headers=auth(owner_token), json=body)
    assert acknowledged.status_code == 200, acknowledged.text
    assert all(r["memo"] == "Later value" and r["is_reconciled"] for r in acknowledged.json())
    changed = {**body, "transaction_ids": list(reversed(body["transaction_ids"]))}
    assert client.post(path, headers=auth(owner_token), json=changed).status_code == 409
    assert client.post(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    with session_factory() as db:
        assert db.query(TransactionChange).count() == count
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("restriction", ["account", "category", "capability"])
def test_bulk_receipt_never_bypasses_current_authority(client, owner_token, session_factory, restriction):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["create_transaction", "edit_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    row = record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, memo="Private")
    path = f"/api/v1/budgets/{budget['id']}/transactions/bulk"
    body = {"transaction_ids": [row["id"]], "action": "set_cleared", "cleared": True,
            "expected_revisions": {row["id"]: row["revision"]}, "mutation_operation_id": str(uuid4())}
    assert client.post(path, headers=auth(token), json=body).status_code == 200
    if restriction == "capability":
        access["capabilities"].remove("edit_transaction")
    else:
        access["restrict_accounts" if restriction == "account" else "restrict_categories"] = True
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    response = client.post(path, headers=auth(token), json=body)
    assert response.status_code == (403 if restriction == "capability" else 404)
    assert "Private" not in response.text


def test_identified_bulk_requires_complete_observations(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    response = client.post(f"/api/v1/budgets/{budget['id']}/transactions/bulk", headers=auth(owner_token),
                           json={"transaction_ids": [str(uuid4())], "action": "set_cleared", "cleared": True,
                                 "mutation_operation_id": str(uuid4())})
    assert response.status_code == 422
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0


def test_noop_receipt_preserves_later_clearing_and_rejects_cross_kind_reuse(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    path = f"/api/v1/budgets/{budget['id']}/transactions"
    identity = str(uuid4())
    body = {"transaction_ids": [row["id"]], "action": "set_cleared", "cleared": False,
            "expected_revisions": {row["id"]: row["revision"]}, "mutation_operation_id": identity}
    assert client.post(f"{path}/bulk", headers=auth(owner_token), json=body).status_code == 200
    with session_factory() as db:
        count = db.query(TransactionChange).count()
        assert db.query(WorkspaceCommandReceipt).count() == 1
        db.get(Transaction, row["id"]).is_cleared = True
        db.commit()
    retry = client.post(f"{path}/bulk", headers=auth(owner_token), json=body)
    assert retry.status_code == 200 and retry.json()[0]["is_cleared"] is True
    edit = {key: row[key] for key in ["account_id", "category_id", "amount_minor", "occurred_on", "payee_name", "memo"]}
    edit.update(memo="Wrong command", mutation_operation_id=identity, expected_revision=retry.json()[0]["revision"])
    assert client.put(f"{path}/{row['id']}", headers=auth(owner_token), json=edit).status_code == 409
    with session_factory() as db:
        assert db.query(TransactionChange).count() == count
        assert db.get(Transaction, row["id"]).memo == row["memo"]
