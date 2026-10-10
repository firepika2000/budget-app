import hashlib
import json
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from app.models import Transaction, TransactionAttachment, TransactionChange, User, WorkspaceCommandReceipt
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure

CONTENT = b"%PDF-1.7\nReviewed receipt"


def fixture(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    account, category = create_budget_structure(client, token, budget["id"])
    transaction = record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}/attachments"
    headers = {**auth(token), "Content-Type": "application/octet-stream", "X-Attachment-Filename": "receipt.pdf",
               "X-Attachment-Content-Type": "application/pdf", "X-Attachment-Operation-ID": str(uuid4())}
    return budget, account, transaction, path, headers


def test_identified_upload_retry_keeps_one_encrypted_object_and_correct_audit_identity(client, owner_token, session_factory, tmp_path):
    _, _, transaction, path, headers = fixture(client, owner_token, session_factory)
    first = client.post(path, headers=headers, content=CONTENT)
    retry = client.post(path, headers=headers, content=CONTENT)
    assert first.status_code == retry.status_code == 201
    assert first.json() == retry.json()
    attachment = first.json()
    assert attachment["sha256"] == hashlib.sha256(CONTENT).hexdigest()
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 1
        assert db.query(WorkspaceCommandReceipt).count() == 1
        change = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="attachment_added").one()
        assert json.loads(change.after_json)["attachment_id"] == attachment["id"]
        assert db.get(Transaction, transaction["id"]).amount_minor == -100
    files = list((tmp_path / "attachments").iterdir())
    assert len(files) == 1 and CONTENT not in files[0].read_bytes()
    assert client.get(f"{path}/{attachment['id']}", headers=auth(owner_token)).content == CONTENT


@pytest.mark.parametrize("change", ["filename", "content", "target", "operation"])
def test_upload_identity_collision_preserves_original(client, owner_token, session_factory, change):
    budget, account, _, path, headers = fixture(client, owner_token, session_factory)
    assert client.post(path, headers=headers, content=CONTENT).status_code == 201
    content = CONTENT
    if change == "filename":
        headers["X-Attachment-Filename"] = "different.pdf"
    elif change == "content":
        content += b"changed"
    elif change == "target":
        other = record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=1)
        path = f"/api/v1/budgets/{budget['id']}/transactions/{other['id']}/attachments"
    else:
        with session_factory() as db:
            db.query(WorkspaceCommandReceipt).one().command_kind = "transaction_void"
            db.commit()
    response = client.post(path, headers=headers, content=content)
    assert response.status_code == 409, response.text
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 1
        assert db.query(TransactionChange).filter_by(action="attachment_added").count() == 1


def test_retry_at_attachment_limit_does_not_consume_another_slot(client, owner_token, session_factory):
    _, _, _, path, headers = fixture(client, owner_token, session_factory)
    first = client.post(path, headers=headers, content=CONTENT)
    assert first.status_code == 201
    for _ in range(19):
        assert client.post(path, headers={**headers, "X-Attachment-Operation-ID": str(uuid4())}, content=CONTENT).status_code == 201
    assert client.post(path, headers=headers, content=CONTENT).json()["id"] == first.json()["id"]
    assert client.post(path, headers={**headers, "X-Attachment-Operation-ID": str(uuid4())}, content=CONTENT).status_code == 422
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 20


def test_detached_accepted_upload_is_never_recreated(client, owner_token, session_factory):
    _, _, _, path, headers = fixture(client, owner_token, session_factory)
    first = client.post(path, headers=headers, content=CONTENT).json()
    assert client.delete(f"{path}/{first['id']}", headers=auth(owner_token)).status_code == 204
    assert client.post(path, headers=headers, content=CONTENT).status_code == 404
    assert client.get(path, headers=auth(owner_token)).json() == []
    with session_factory() as db:
        attachment = db.get(TransactionAttachment, first["id"])
        assert attachment.detached_at is not None and attachment.purge_after is not None
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("restriction", ["account", "category", "capability", "ownership"])
def test_upload_receipt_rechecks_current_access(client, owner_token, session_factory, restriction):
    budget, _, transaction, path, headers = fixture(client, owner_token, session_factory)
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
    assert client.post(path, headers=headers, content=CONTENT).status_code == 201
    if restriction == "ownership":
        with session_factory() as db:
            db.get(Transaction, transaction["id"]).created_by_user_id = db.query(User).filter_by(email="owner@example.com").one().id
            db.commit()
    else:
        if restriction == "account": access.update(restrict_accounts=True, account_ids=[])
        elif restriction == "category": access.update(restrict_categories=True, category_ids=[])
        else: access["capabilities"].remove("edit_transaction")
        assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    response = client.post(path, headers=headers, content=CONTENT)
    assert response.status_code == (404 if restriction in {"account", "category"} else 403), response.text
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 1


@pytest.mark.parametrize("damage", ["missing", "corrupt"])
def test_retry_does_not_acknowledge_lost_or_corrupt_storage(client, owner_token, session_factory, tmp_path, damage):
    _, _, _, path, headers = fixture(client, owner_token, session_factory)
    assert client.post(path, headers=headers, content=CONTENT).status_code == 201
    file = next((tmp_path / "attachments").iterdir())
    if damage == "missing": file.unlink()
    else: file.write_bytes(b"invalid ciphertext")
    assert client.post(path, headers=headers, content=CONTENT).status_code == 500
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 1
        assert db.query(WorkspaceCommandReceipt).count() == 1


def test_failed_database_commit_removes_tentative_encrypted_object(client, owner_token, session_factory, tmp_path, monkeypatch):
    _, _, _, path, headers = fixture(client, owner_token, session_factory)
    def fail_commit(self):
        raise RuntimeError("Injected failed publication")
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail_commit)
        with pytest.raises(RuntimeError, match="Injected failed publication"):
            client.post(path, headers=headers, content=CONTENT)
    with session_factory() as db:
        assert db.query(TransactionAttachment).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(TransactionChange).filter_by(action="attachment_added").count() == 0
    assert list((tmp_path / "attachments").iterdir()) == []
    assert client.post(path, headers=headers, content=CONTENT).status_code == 201
