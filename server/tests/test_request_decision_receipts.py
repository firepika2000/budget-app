from datetime import date

import pytest
from sqlalchemy.orm import Session

from app import budgeting_routes, request_routes
from app.models import AllocationOperation, FinancialRequest, RequestAction, WorkspaceCommandReceipt
from .conftest import auth, freeze_today
from .test_advanced_ledger import add_category, record
from .test_request_creation_receipts import setup
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


@pytest.fixture
def decision_context(client, owner_token, session_factory, monkeypatch):
    freeze_today(monkeypatch, date(2026, 9, 15), budgeting_routes, request_routes)
    budget, account, destination, path, request, headers = setup(client, owner_token, session_factory)
    source = add_category(client, owner_token, budget["id"], "Family", "Request funding")
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=20_000, is_cleared=True)
    root = f"/api/v1/budgets/{budget['id']}"
    assigned = client.put(f"{root}/categories/{source['id']}/assignment", headers=auth(owner_token),
                          json={"month": "2026-09-01", "assigned_minor": 10_000})
    assert assigned.status_code == 200, assigned.text
    created = client.post(path, headers=auth(owner_token), json={**request, "requested_amount_minor": 3000})
    assert created.status_code == 201, created.text
    return budget, account, source, destination, root, created.json(), headers


def observations(client, token, root):
    result = {}
    for suffix in ["/transactions", "/account-balances", "/months/2026-09-01"]:
        response = client.get(root + suffix, headers=auth(token))
        assert response.status_code == 200, response.text
        result[suffix] = response.json()
    return result


def decision_body(source, decision="approve"):
    body = {"decision": decision, "expected_request_version": 0, "note": "Reviewed decision"}
    if decision == "approve":
        body.update(approved_amount_minor=1500, source_category_id=source["id"])
    return body


@pytest.mark.parametrize("decision", ["approve", "reject", "changes_requested"])
def test_decision_retry_publishes_one_action_and_no_second_money_move(
    client, owner_token, session_factory, decision_context, decision
):
    _, _, source, destination, root, request, headers = decision_context
    url = f"{root}/requests/{request['id']}/decision"
    body = decision_body(source, decision)
    before = observations(client, owner_token, root)
    first = client.post(url, headers=headers, json=body)
    retry = client.post(url, headers=headers, json=body)
    assert first.status_code == retry.status_code == 200, retry.text
    assert first.json() == retry.json() and first.json()["version"] == 1
    after = observations(client, owner_token, root)
    assert after["/transactions"] == before["/transactions"]
    assert after["/account-balances"] == before["/account-balances"]
    assert after["/months/2026-09-01"]["ready_to_assign_minor"] == before["/months/2026-09-01"]["ready_to_assign_minor"]
    if decision == "approve":
        categories = {row["category_id"]: row for row in after["/months/2026-09-01"]["categories"]}
        assert categories[source["id"]]["available_minor"] == 8500
        assert categories[destination["id"]]["available_minor"] == 1500
        # Later source spending/allocation changes cannot turn receipt acknowledgement into a
        # new funding attempt. The accepted approval remains accepted even when funds are gone.
        assert client.put(f"{root}/categories/{source['id']}/assignment", headers=auth(owner_token),
                          json={"month": "2026-09-01", "assigned_minor": 1500}).status_code == 200
    elif decision == "changes_requested":
        revised = client.post(f"{root}/requests/{request['id']}/revise", headers=auth(owner_token), json={
            "destination_category_id": destination["id"], "requested_amount_minor": 2000,
            "reason": "Later revision", "expected_request_version": 1,
        })
        assert revised.status_code == 200, revised.text
        assert client.post(url, headers=auth(owner_token), json={
            "decision": "reject", "expected_request_version": 2, "note": "Later final decision",
        }).status_code == 200
    stable = observations(client, owner_token, root)
    acknowledged = client.post(url, headers=headers, json=body)
    assert acknowledged.status_code == 200, acknowledged.text
    if decision == "changes_requested":
        assert acknowledged.json()["status"] == "rejected" and acknowledged.json()["version"] == 3
    assert observations(client, owner_token, root) == stable
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="funding_request_decide").count() == 1
        assert db.query(AllocationOperation).filter_by(kind="request_approval").count() == int(decision == "approve")
        action = {"approve": "partially_approved", "reject": "rejected", "changes_requested": "changes_requested"}[decision]
        assert db.query(RequestAction).filter_by(request_id=request["id"], action=action).count() == 1


@pytest.mark.parametrize("field,value", [("note", "Changed"), ("approved_amount_minor", 1000),
                                         ("source_category_id", "another"), ("expected_request_version", 1)])
def test_decision_identity_rejects_changed_intent(client, owner_token, session_factory, decision_context, field, value):
    _, _, source, _, root, request, headers = decision_context
    body = decision_body(source)
    url = f"{root}/requests/{request['id']}/decision"
    assert client.post(url, headers=headers, json=body).status_code == 200
    stable = observations(client, owner_token, root)
    assert client.post(url, headers=headers, json={**body, field: value}).status_code == 409
    assert observations(client, owner_token, root) == stable


@pytest.mark.parametrize("revoked", ["source", "destination", "capability"])
def test_approver_only_capability_and_replay_scope(client, owner_token, session_factory, decision_context, revoked):
    budget, account, source, destination, root, request, headers = decision_context
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_categories", "approve_request"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [source["id"], destination["id"]], capabilities)
    capability = client.get(f"{root}/requests/capabilities", headers=auth(token))
    assert capability.status_code == 200 and capability.json() == {
        "creation_replay_version": 0, "cancellation_replay_version": 0, "revision_replay_version": 0, "decision_replay_version": 1,
    }
    url = f"{root}/requests/{request['id']}/decision"
    headers = {**headers, **auth(token)}
    assert client.post(url, headers=headers, json=decision_body(source)).status_code == 200
    allowed = [source["id"], destination["id"]]
    if revoked != "capability":
        allowed.remove(source["id"] if revoked == "source" else destination["id"])
    changed = client.put(f"{root}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities[:-1] if revoked == "capability" else capabilities,
        "restrict_accounts": False, "account_ids": [], "restrict_categories": True, "category_ids": allowed,
    })
    assert changed.status_code == 200, changed.text
    stable = observations(client, owner_token, root)
    assert client.post(url, headers=headers, json=decision_body(source)).status_code in {403, 404}
    assert observations(client, owner_token, root) == stable


def test_failed_decision_receipt_rolls_back_money_request_and_action(client, owner_token, session_factory, decision_context, monkeypatch):
    _, _, source, _, root, request, headers = decision_context
    stable = observations(client, owner_token, root)
    original = Session.commit
    def fail(db):
        if any(isinstance(row, WorkspaceCommandReceipt) for row in db.new):
            raise RuntimeError("Injected decision publication failure")
        return original(db)
    with monkeypatch.context() as patch:
        patch.setattr(Session, "commit", fail)
        with pytest.raises(RuntimeError, match="Injected decision"):
            client.post(f"{root}/requests/{request['id']}/decision", headers=headers, json=decision_body(source))
    assert observations(client, owner_token, root) == stable
    with session_factory() as db:
        assert db.get(FinancialRequest, request["id"]).status == "pending"
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(AllocationOperation).filter_by(kind="request_approval").count() == 0
        assert db.query(RequestAction).filter_by(action="partially_approved").count() == 0
    assert client.post(f"{root}/requests/{request['id']}/decision", headers=headers, json=decision_body(source)).status_code == 200


@pytest.mark.parametrize("changed", ["decision", "resource", "kind"])
def test_decision_identity_is_bound_to_action_resource_and_kind(client, owner_token, session_factory, decision_context, changed):
    _, _, source, destination, root, request, headers = decision_context
    body = decision_body(source)
    url = f"{root}/requests/{request['id']}/decision"
    assert client.post(url, headers=headers, json=body).status_code == 200
    if changed == "decision":
        body = {"decision": "reject", "expected_request_version": 0, "note": "Different action"}
    elif changed == "resource":
        other = client.post(f"{root}/requests", headers=auth(owner_token), json={
            "destination_category_id": destination["id"], "requested_amount_minor": 3000, "reason": "Another request",
        })
        assert other.status_code == 201, other.text
        url = f"{root}/requests/{other.json()['id']}/decision"
    else:
        with session_factory() as db:
            db.query(WorkspaceCommandReceipt).one().command_kind = "funding_request_revise"
            db.commit()
    stable = observations(client, owner_token, root)
    assert client.post(url, headers=headers, json=body).status_code == 409
    assert observations(client, owner_token, root) == stable
    with session_factory() as db:
        assert db.query(AllocationOperation).filter_by(kind="request_approval").count() == 1


def test_decision_identity_validation_preserves_legacy_contract(client, owner_token, session_factory, decision_context):
    _, _, source, _, root, request, headers = decision_context
    url = f"{root}/requests/{request['id']}/decision"
    body = decision_body(source)
    before = observations(client, owner_token, root)
    assert client.post(url, headers={**headers, "X-Request-Operation-ID": "invalid"}, json=body).status_code == 422
    assert observations(client, owner_token, root) == before
    assert client.post(url, headers=auth(owner_token), json=body).status_code == 200
    stable = observations(client, owner_token, root)
    assert client.post(url, headers=auth(owner_token), json=body).status_code == 409
    assert observations(client, owner_token, root) == stable
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
