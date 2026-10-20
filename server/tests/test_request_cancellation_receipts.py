import pytest
from sqlalchemy.orm import Session

from app.models import FinancialRequest, RequestAction, WorkspaceCommandReceipt
from .conftest import auth
from .test_delegated_access import add_child
from .test_request_creation_receipts import setup
from .test_scheduled_transactions_contract import grant_planner


def create_request(client, token, path, body):
    response = client.post(path, headers=auth(token), json=body)
    assert response.status_code == 201, response.text
    return response.json()


def test_cancel_retry_has_one_action_and_preserves_financial_observations(client, owner_token, session_factory):
    budget, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = create_request(client, owner_token, path, body)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/transactions", "/months/2099-01-01"]}
    url = f"{path}/{request['id']}/cancel"
    intent = {"expected_request_version": request["version"], "note": "No longer needed"}
    first = client.post(url, headers=headers, json=intent)
    retry = client.post(url, headers=headers, json=intent)
    assert first.status_code == retry.status_code == 200, retry.text
    assert first.json() == retry.json()
    assert first.json()["status"] == "cancelled"
    assert first.json()["version"] == request["version"] + 1
    assert first.json()["requested_amount_minor"] == 9007199254740993
    for suffix, observation in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == observation
    with session_factory() as db:
        assert db.query(RequestAction).filter_by(request_id=request["id"], action="cancelled").count() == 1
        receipt = db.query(WorkspaceCommandReceipt).one()
        assert receipt.command_kind == "funding_request_cancel" and receipt.resource_id == request["id"]


@pytest.mark.parametrize("changed", ["note", "version", "resource", "kind"])
def test_cancel_identity_cannot_change_intent(client, owner_token, session_factory, changed):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = create_request(client, owner_token, path, body)
    url = f"{path}/{request['id']}/cancel"
    intent = {"expected_request_version": request["version"], "note": "Original"}
    assert client.post(url, headers=headers, json=intent).status_code == 200
    if changed == "note":
        intent["note"] = "Changed"
    elif changed == "version":
        intent["expected_request_version"] += 1
    elif changed == "resource":
        another = create_request(client, owner_token, path, body)
        url = f"{path}/{another['id']}/cancel"
    else:
        with session_factory() as db:
            db.query(WorkspaceCommandReceipt).one().command_kind = "funding_request_create"
            db.commit()
    assert client.post(url, headers=headers, json=intent).status_code == 409
    with session_factory() as db:
        assert db.query(RequestAction).filter_by(action="cancelled").count() == 1
        if changed == "resource":
            assert db.get(FinancialRequest, another["id"]).status == "pending"


@pytest.mark.parametrize("revoked", ["category", "capability"])
def test_cancel_replay_rechecks_authorization(client, owner_token, session_factory, revoked):
    budget, account, category, path, body, headers = setup(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_categories", "request_money"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], capabilities)
    request = create_request(client, token, path, body)
    url = f"{path}/{request['id']}/cancel"
    headers = {**headers, **auth(token)}
    intent = {"expected_request_version": request["version"]}
    assert client.post(url, headers=headers, json=intent).status_code == 200
    response = client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities if revoked == "category" else capabilities[:-1],
        "restrict_accounts": False, "account_ids": [], "restrict_categories": True,
        "category_ids": [] if revoked == "category" else [category["id"]],
    })
    assert response.status_code == 200, response.text
    assert client.post(url, headers=headers, json=intent).status_code in {403, 404}
    with session_factory() as db:
        assert db.query(RequestAction).filter_by(action="cancelled").count() == 1


def test_cancel_legacy_validation_and_stale_version(client, owner_token, session_factory):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = create_request(client, owner_token, path, body)
    url = f"{path}/{request['id']}/cancel"
    assert client.post(url, headers={**headers, "X-Request-Operation-ID": "invalid"},
                       json={"expected_request_version": 0}).status_code == 422
    assert client.post(url, headers=headers, json={"expected_request_version": 1}).status_code == 409
    assert client.post(url, headers=auth(owner_token), json={"expected_request_version": 0}).status_code == 200
    assert client.post(url, headers=auth(owner_token), json={"expected_request_version": 0}).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(RequestAction).filter_by(action="cancelled").count() == 1


def test_cancel_failure_rolls_back_transition_action_and_receipt(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, body, headers = setup(client, owner_token, session_factory)
    request = create_request(client, owner_token, path, body)
    original = Session.commit
    def fail(db):
        if any(isinstance(row, WorkspaceCommandReceipt) for row in db.new):
            raise RuntimeError("Injected cancellation publication failure")
        return original(db)
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail)
        with pytest.raises(RuntimeError, match="Injected cancellation"):
            client.post(f"{path}/{request['id']}/cancel", headers=headers, json={"expected_request_version": 0})
    with session_factory() as db:
        assert db.get(FinancialRequest, request["id"]).status == "pending"
        assert db.query(RequestAction).filter_by(action="cancelled").count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.post(f"{path}/{request['id']}/cancel", headers=headers,
                       json={"expected_request_version": 0}).status_code == 200


def test_cancel_receipt_never_authorizes_another_actor_or_missing_resource(client, owner_token, session_factory):
    budget, account, category, path, body, headers = setup(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]],
                  ["view_budget", "view_categories", "request_money"])
    request = create_request(client, token, path, body)
    url = f"{path}/{request['id']}/cancel"
    intent = {"expected_request_version": 0}
    child_headers = {**headers, **auth(token)}
    assert client.post(url, headers=child_headers, json=intent).status_code == 200
    assert client.post(url, headers=headers, json=intent).status_code == 404
    with session_factory() as db:
        db.query(RequestAction).filter_by(request_id=request["id"]).delete()
        db.delete(db.get(FinancialRequest, request["id"]))
        db.commit()
    assert client.post(url, headers=child_headers, json=intent).status_code == 404
    with session_factory() as db:
        assert db.query(FinancialRequest).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 1
