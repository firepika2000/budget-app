from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from app.models import FinancialRequest, RequestAction, WorkspaceCommandReceipt
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def setup(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    account, category = create_budget_structure(client, token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}/requests"
    body = dict(destination_category_id=category["id"], requested_amount_minor=9007199254740993,
                reason="Reviewed offline intent", request_type="additional_allocation")
    headers = {**auth(token), "X-Request-Operation-ID": str(uuid4())}
    return budget, account, category, path, body, headers


def test_request_retry_is_money_neutral_and_does_not_reset_cancellation(client, owner_token, session_factory):
    budget, _, _, path, body, headers = setup(client, owner_token, session_factory)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/transactions", "/months/2099-01-01"]}
    first = client.post(path, headers=headers, json=body)
    retry = client.post(path, headers=headers, json=body)
    assert first.status_code == retry.status_code == 201, retry.text
    assert first.json() == retry.json()
    assert first.json()["requested_amount_minor"] == 9007199254740993
    cancelled = client.post(f"{path}/{first.json()['id']}/cancel", headers=auth(owner_token),
                            json={"expected_request_version": first.json()["version"], "note": "Not needed"})
    assert cancelled.status_code == 200, cancelled.text
    acknowledged = client.post(path, headers=headers, json=body)
    assert acknowledged.status_code == 201, acknowledged.text
    assert acknowledged.json()["status"] == "cancelled"
    assert acknowledged.json()["id"] == first.json()["id"]
    for suffix, value in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == value
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(RequestAction).filter_by(action="submitted").count() == 1


@pytest.mark.parametrize("field,value", [("requested_amount_minor", 2), ("reason", "Changed"),
                                         ("request_type", "purchase_approval")])
def test_changed_request_intent_cannot_reuse_identity(client, owner_token, session_factory, field, value):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    assert client.post(path, headers=headers, json=body).status_code == 201
    assert client.post(path, headers=headers, json={**body, field: value}).status_code == 409
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == 1


@pytest.mark.parametrize("revoked", ["capability", "category"])
def test_request_acknowledgement_rechecks_current_scope(client, owner_token, session_factory, revoked):
    budget, account, category, path, body, headers = setup(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_categories", "request_money"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], capabilities)
    headers = {**headers, **auth(token)}
    assert client.post(path, headers=headers, json=body).status_code == 201
    changed = client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities if revoked == "category" else capabilities[:-1],
        "restrict_accounts": False, "account_ids": [], "restrict_categories": True,
        "category_ids": [] if revoked == "category" else [category["id"]],
    })
    assert changed.status_code == 200, changed.text
    assert client.post(path, headers=headers, json=body).status_code in {403, 404}
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == db.query(WorkspaceCommandReceipt).count() == 1


def test_request_identity_validation_and_legacy_contract(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    capability = client.get(path + "/capabilities", headers=auth(owner_token))
    assert capability.status_code == 200 and capability.json() == {"creation_replay_version": 1}
    assert client.get(path + "/capabilities").status_code == 401
    assert client.post(path, headers={**headers, "X-Request-Operation-ID": "invalid"}, json=body).status_code == 422
    for _ in range(2):
        assert client.post(path, headers=auth(owner_token), json=body).status_code == 201
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == 2
        assert db.query(WorkspaceCommandReceipt).count() == 0


def test_request_receipt_kind_and_missing_resource_cannot_be_reused(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    first = client.post(path, headers=headers, json=body)
    assert first.status_code == 201
    with session_factory() as db:
        receipt = db.query(WorkspaceCommandReceipt).one()
        receipt.command_kind = "schedule_create"
        db.commit()
    assert client.post(path, headers=headers, json=body).status_code == 409
    with session_factory() as db:
        receipt = db.query(WorkspaceCommandReceipt).one()
        receipt.command_kind = "funding_request_create"
        receipt.resource_id = str(uuid4())
        db.commit()
    assert client.post(path, headers=headers, json=body).status_code == 404
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == 1
        assert db.query(RequestAction).filter_by(action="submitted").count() == 1


def test_failed_request_commit_keeps_identity_retryable(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    original = Session.commit
    def fail(db):
        if any(isinstance(row, WorkspaceCommandReceipt) for row in db.new):
            raise RuntimeError("Injected request publication failure")
        return original(db)
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail)
        with pytest.raises(RuntimeError, match="Injected request"):
            client.post(path, headers=headers, json=body)
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == 0
        assert db.query(RequestAction).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.post(path, headers=headers, json=body).status_code == 201
