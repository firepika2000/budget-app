from uuid import uuid4

import pytest

from app.models import ScheduledTransaction, ScheduledTransactionRevision, WorkspaceCommandReceipt
from sqlalchemy.orm import Session
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def setup(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    account, category = create_budget_structure(client, token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}/scheduled-transactions"
    body = dict(account_id=account["id"], category_id=category["id"], name="Reviewed recurring expense",
                amount_minor=-9007199254740993, next_date="2099-01-01", recurrence_unit="months", memo="original")
    headers = {**auth(token), "X-Planning-Operation-ID": str(uuid4())}
    return budget, account, category, path, body, headers


def test_identified_schedule_retry_is_money_neutral_and_does_not_reset_later_pause(client, owner_token, session_factory):
    budget, _, _, path, body, headers = setup(client, owner_token, session_factory)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/transactions", "/months/2099-01-01"]}
    first = client.post(path, headers=headers, json=body)
    retry = client.post(path, headers=headers, json=body)
    assert first.status_code == retry.status_code == 201, retry.text
    assert first.json() == retry.json()
    identity = first.json()["id"]
    assert first.json()["amount_minor"] == -9007199254740993
    assert client.put(f"{path}/{identity}", headers=auth(owner_token), json={**body, "memo": "later edit", "is_active": False}).status_code == 200
    accepted = client.post(path, headers=headers, json=body)
    assert accepted.status_code == 201 and accepted.json()["is_active"] is False
    assert accepted.json()["memo"] == "later edit"
    for suffix, value in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == value
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 1
        assert db.query(ScheduledTransactionRevision).filter_by(action="created").count() == 1
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("field,value", [("amount_minor", -2), ("memo", "different"), ("next_date", "2099-02-01")])
def test_changed_schedule_intent_cannot_reuse_identity(client, owner_token, session_factory, field, value):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    assert client.post(path, headers=headers, json=body).status_code == 201
    response = client.post(path, headers=headers, json={**body, field: value})
    assert response.status_code == 409, response.text
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 1


def test_deleted_schedule_retry_does_not_resurrect(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    first = client.post(path, headers=headers, json=body).json()
    assert client.delete(f"{path}/{first['id']}", headers=auth(owner_token)).status_code == 204
    assert client.post(path, headers=headers, json=body).status_code == 404
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("revoked", ["capability", "account", "category"])
def test_schedule_acknowledgement_rechecks_current_scope(client, owner_token, session_factory, revoked):
    budget, account, category, path, body, headers = setup(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], capabilities)
    headers = {**headers, **auth(token)}
    assert client.post(path, headers=headers, json=body).status_code == 201
    response = client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities if revoked != "capability" else capabilities[:-1],
        "restrict_accounts": True, "account_ids": [] if revoked == "account" else [account["id"]],
        "restrict_categories": True, "category_ids": [] if revoked == "category" else [category["id"]],
    })
    assert response.status_code == 200, response.text
    assert client.post(path, headers=headers, json=body).status_code in {403, 404}
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == db.query(WorkspaceCommandReceipt).count() == 1


def test_wrong_command_kind_and_invalid_identity_fail_without_new_schedule(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    assert client.post(path, headers=headers, json=body).status_code == 201
    with session_factory() as db:
        db.query(WorkspaceCommandReceipt).one().command_kind = "transaction_void"
        db.commit()
    assert client.post(path, headers=headers, json=body).status_code == 409
    assert client.post(path, headers={**headers, "X-Planning-Operation-ID": "bad"}, json=body).status_code == 422
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 1


def test_unidentified_schedule_creation_preserves_legacy_contract(client, owner_token, session_factory):
    _, _, _, path, body, _ = setup(client, owner_token, session_factory)
    for _ in range(2):
        assert client.post(path, headers=auth(owner_token), json=body).status_code == 201
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 2
        assert db.query(WorkspaceCommandReceipt).count() == 0


def test_failed_schedule_commit_keeps_identity_retryable_without_partial_history(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    original = Session.commit
    def fail(db):
        if any(isinstance(value, WorkspaceCommandReceipt) for value in db.new):
            raise RuntimeError("Injected schedule publication failure")
        return original(db)
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail)
        with pytest.raises(RuntimeError, match="Injected schedule"):
            client.post(path, headers=headers, json=body)
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == 0
        assert db.query(ScheduledTransactionRevision).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.post(path, headers=headers, json=body).status_code == 201
