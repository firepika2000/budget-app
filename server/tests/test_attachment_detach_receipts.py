from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from app.models import Transaction, TransactionAttachment, TransactionChange, User, WorkspaceCommandReceipt
from .conftest import auth
from .test_attachment_upload_receipts import CONTENT, fixture
from .test_budgeting_api import add_member


def reviewed_removal(client, token, factory):
    budget, account, transaction, path, upload_headers = fixture(client, token, factory)
    uploaded = client.post(path, headers=upload_headers, content=CONTENT)
    assert uploaded.status_code == 201, uploaded.text
    file = uploaded.json()
    headers = {**auth(token), "X-Attachment-Operation-ID": str(uuid4())}
    return budget, transaction, f"{path}/{file['id']}", headers, {"expected_sha256": file["sha256"]}


def test_lost_removal_response_acknowledges_without_extending_tombstone_or_changing_money(client, owner_token, session_factory):
    budget, transaction, path, headers, params = reviewed_removal(client, owner_token, session_factory)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/accounts", "/months/2026-09-01"]}
    assert client.delete(path, headers=headers, params=params).status_code == 204
    with session_factory() as db:
        file = db.query(TransactionAttachment).one()
        original = (file.detached_at, file.purge_after, file.detached_by_user_id)
        assert (file.purge_after - file.detached_at).days == 30
    assert client.delete(path, headers=headers, params=params).status_code == 204
    with session_factory() as db:
        file = db.query(TransactionAttachment).one()
        assert (file.detached_at, file.purge_after, file.detached_by_user_id) == original
        assert db.query(TransactionChange).filter_by(action="attachment_detached").count() == 1
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="attachment_detach").count() == 1
        db.delete(file)
        db.commit()
    assert client.delete(path, headers=headers, params=params).status_code == 204
    assert client.get(path, headers=auth(owner_token)).status_code == 404
    for suffix, observation in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == observation
    with session_factory() as db:
        actual = db.get(Transaction, transaction["id"])
        assert actual.amount_minor == transaction["amount_minor"]
        assert actual.payee_name == transaction["payee_name"]
        assert actual.is_cleared == transaction["is_cleared"]
        assert actual.is_reconciled == transaction["is_reconciled"]


@pytest.mark.parametrize("failure", ["missing_digest", "wrong_digest", "invalid_uuid", "changed_intent", "wrong_kind"])
def test_removal_identity_rejects_invalid_or_rebound_intent(client, owner_token, session_factory, failure):
    _, _, path, headers, params = reviewed_removal(client, owner_token, session_factory)
    expected = 409
    if failure == "missing_digest":
        params = {}; expected = 422
    elif failure == "wrong_digest":
        params["expected_sha256"] = "0" * 64
    elif failure == "invalid_uuid":
        headers["X-Attachment-Operation-ID"] = "bad"; expected = 422
    else:
        assert client.delete(path, headers=headers, params=params).status_code == 204
        if failure == "changed_intent":
            params["expected_sha256"] = "0" * 64
        else:
            with session_factory() as db:
                db.query(WorkspaceCommandReceipt).filter_by(command_kind="attachment_detach").one().command_kind = "attachment_upload"
                db.commit()
    assert client.delete(path, headers=headers, params=params).status_code == expected


def test_failed_removal_commit_rolls_back_tombstone_audit_and_receipt(client, owner_token, session_factory, monkeypatch):
    _, _, path, headers, params = reviewed_removal(client, owner_token, session_factory)
    commit = Session.commit
    def fail(db):
        raise RuntimeError("Injected failed commit")
    monkeypatch.setattr(Session, "commit", fail)
    with pytest.raises(RuntimeError, match="failed commit"):
        client.delete(path, headers=headers, params=params)
    monkeypatch.setattr(Session, "commit", commit)
    with session_factory() as db:
        assert db.query(TransactionAttachment).one().detached_at is None
        assert db.query(TransactionChange).filter_by(action="attachment_detached").count() == 0
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="attachment_detach").count() == 0
    assert client.delete(path, headers=headers, params=params).status_code == 204


def test_legacy_removal_keeps_not_found_retry_behavior(client, owner_token, session_factory):
    _, _, path, _, _ = reviewed_removal(client, owner_token, session_factory)
    assert client.delete(path, headers=auth(owner_token)).status_code == 204
    assert client.delete(path, headers=auth(owner_token)).status_code == 404


@pytest.mark.parametrize("restriction", ["account", "category", "capability", "ownership"])
def test_accepted_removal_rechecks_current_scope_and_ownership(client, owner_token, session_factory, restriction):
    budget, transaction, path, headers, params = reviewed_removal(client, owner_token, session_factory)
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
        db.get(Transaction, transaction["id"]).created_by_user_id = member
        db.commit()
    access = {"capabilities": ["edit_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    headers.update(auth(token))
    assert client.delete(path, headers=headers, params=params).status_code == 204
    if restriction == "ownership":
        with session_factory() as db:
            db.get(Transaction, transaction["id"]).created_by_user_id = db.query(User).filter_by(email="owner@example.com").one().id
            db.commit()
    else:
        if restriction == "account": access.update(restrict_accounts=True, account_ids=[])
        elif restriction == "category": access.update(restrict_categories=True, category_ids=[])
        else: access["capabilities"].remove("edit_transaction")
        assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    assert client.delete(path, headers=headers, params=params).status_code == (404 if restriction in {"account", "category"} else 403)
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(action="attachment_detached").count() == 1
