import pytest
from sqlalchemy.orm import Session

from app.models import FinancialRequest, RequestAction, WorkspaceCommandReceipt
from .conftest import auth
from .test_delegated_access import add_child
from .test_request_creation_receipts import setup
from .test_scheduled_transactions_contract import grant_planner


def review_request(client, owner_token, requester_token, path, body):
    created = client.post(path, headers=auth(requester_token), json=body)
    assert created.status_code == 201, created.text
    request = created.json()
    response = client.post(f"{path}/{request['id']}/decision", headers=auth(owner_token), json={
        "decision": "changes_requested", "expected_request_version": request["version"], "note": "Please clarify",
    })
    assert response.status_code == 200, response.text
    return response.json()


def test_revision_retry_keeps_one_action_and_never_undoes_later_decision(client, owner_token, session_factory):
    budget, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = review_request(client, owner_token, owner_token, path, body)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/transactions", "/months/2099-01-01"]}
    url = f"{path}/{request['id']}/revise"
    intent = {**body, "reason": "Clarified", "expected_request_version": request["version"]}
    first = client.post(url, headers=headers, json=intent)
    retry = client.post(url, headers=headers, json=intent)
    assert first.status_code == retry.status_code == 200, retry.text
    assert first.json() == retry.json()
    assert first.json()["version"] == 2 and first.json()["status"] == "pending"
    assert first.json()["requested_amount_minor"] == 9007199254740993
    expires_at = first.json()["expires_at"]
    rejected = client.post(f"{path}/{request['id']}/decision", headers=auth(owner_token), json={
        "decision": "reject", "expected_request_version": 2, "note": "Final decision",
    })
    assert rejected.status_code == 200, rejected.text
    acknowledged = client.post(url, headers=headers, json=intent)
    assert acknowledged.status_code == 200, acknowledged.text
    assert acknowledged.json()["status"] == "rejected" and acknowledged.json()["version"] == 3
    assert acknowledged.json()["expires_at"] == expires_at
    for suffix, observation in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == observation
    with session_factory() as db:
        assert db.query(RequestAction).filter_by(request_id=request["id"], action="revised").count() == 1
        receipt = db.query(WorkspaceCommandReceipt).one()
        assert receipt.command_kind == "funding_request_revise" and receipt.resource_id == request["id"]


@pytest.mark.parametrize("field,value", [
    ("reason", "Changed"), ("requested_amount_minor", 1),
    ("request_type", "purchase_approval"), ("expected_request_version", 2),
    ("destination_category_id", "another-category"),
])
def test_revision_identity_rejects_changed_intent(client, owner_token, session_factory, field, value):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = review_request(client, owner_token, owner_token, path, body)
    url = f"{path}/{request['id']}/revise"
    intent = {**body, "expected_request_version": request["version"]}
    assert client.post(url, headers=headers, json=intent).status_code == 200
    assert client.post(url, headers=headers, json={**intent, field: value}).status_code == 409
    with session_factory() as db:
        assert db.get(FinancialRequest, request["id"]).version == 2
        assert db.query(RequestAction).filter_by(action="revised").count() == 1


@pytest.mark.parametrize("revoked", ["category", "capability"])
def test_revision_replay_rechecks_current_scope(client, owner_token, session_factory, revoked):
    budget, account, category, path, body, headers = setup(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_categories", "request_money"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], capabilities)
    request = review_request(client, owner_token, token, path, body)
    url = f"{path}/{request['id']}/revise"
    headers = {**headers, **auth(token)}
    intent = {**body, "expected_request_version": request["version"]}
    assert client.post(url, headers=headers, json=intent).status_code == 200
    response = client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities if revoked == "category" else capabilities[:-1],
        "restrict_accounts": False, "account_ids": [], "restrict_categories": True,
        "category_ids": [] if revoked == "category" else [category["id"]],
    })
    assert response.status_code == 200, response.text
    assert client.post(url, headers=headers, json=intent).status_code in {403, 404}


def test_revision_validation_legacy_and_conflicting_kind(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = review_request(client, owner_token, owner_token, path, body)
    url = f"{path}/{request['id']}/revise"
    intent = {**body, "expected_request_version": 1}
    assert client.post(url, headers={**headers, "X-Request-Operation-ID": "invalid"}, json=intent).status_code == 422
    assert client.post(url, headers=headers, json={**intent, "expected_request_version": 0}).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.post(url, headers=headers, json=intent).status_code == 200
    with session_factory() as db:
        db.query(WorkspaceCommandReceipt).one().command_kind = "funding_request_cancel"
        db.commit()
    assert client.post(url, headers=headers, json=intent).status_code == 409
    legacy = review_request(client, owner_token, owner_token, path, body)
    legacy_url = f"{path}/{legacy['id']}/revise"
    assert client.post(legacy_url, headers=auth(owner_token), json=intent).status_code == 200
    assert client.post(legacy_url, headers=auth(owner_token), json=intent).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1


def test_revision_publication_failure_is_atomic_and_retryable(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = review_request(client, owner_token, owner_token, path, body)
    intent = {**body, "reason": "New explanation", "expected_request_version": 1}
    original = Session.commit
    def fail(db):
        if any(isinstance(row, WorkspaceCommandReceipt) for row in db.new):
            raise RuntimeError("Injected revision publication failure")
        return original(db)
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail)
        with pytest.raises(RuntimeError, match="Injected revision"):
            client.post(f"{path}/{request['id']}/revise", headers=headers, json=intent)
    with session_factory() as db:
        item = db.get(FinancialRequest, request["id"])
        assert item.status == "changes_requested" and item.version == 1 and item.reason == body["reason"]
        assert db.query(RequestAction).filter_by(action="revised").count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.post(f"{path}/{request['id']}/revise", headers=headers, json=intent).status_code == 200


def test_revision_receipt_is_bound_to_resource_and_does_not_resurrect_it(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    first = review_request(client, owner_token, owner_token, path, body)
    second = review_request(client, owner_token, owner_token, path, body)
    intent = {**body, "expected_request_version": 1}
    url = f"{path}/{first['id']}/revise"
    assert client.post(url, headers=headers, json=intent).status_code == 200
    assert client.post(f"{path}/{second['id']}/revise", headers=headers, json=intent).status_code == 409
    with session_factory() as db:
        assert db.get(FinancialRequest, second["id"]).status == "changes_requested"
        db.query(RequestAction).filter_by(request_id=first["id"]).delete()
        db.delete(db.get(FinancialRequest, first["id"]))
        db.commit()
    assert client.post(url, headers=headers, json=intent).status_code == 404
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(FinancialRequest).count() == 1
