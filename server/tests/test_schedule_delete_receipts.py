from datetime import date
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from app import planning_routes
from app.models import ScheduledTransaction, ScheduledTransactionRevision, WorkspaceCommandReceipt
from .conftest import auth, freeze_today
from .test_schedule_edit_receipts import reviewed_edit
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def reviewed_delete(client, token, factory):
    budget, account, category, path, _, schedule = reviewed_edit(client, token, factory)
    return budget, account, category, path, schedule, {
        "headers": {**auth(token), "X-Planning-Operation-ID": str(uuid4())},
        "params": {"expected_revision": schedule["revision"]},
    }


def test_identified_schedule_deletion_retry_is_money_neutral(client, owner_token, session_factory):
    budget, _, _, path, schedule, request = reviewed_delete(client, owner_token, session_factory)
    root = f"/api/v1/budgets/{budget['id']}"
    before = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
              for suffix in ["/transactions", "/months/2099-01-01"]}
    assert client.delete(path, **request).status_code == 204
    assert client.delete(path, **request).status_code == 204
    for suffix, value in before.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == value
    with session_factory() as db:
        assert db.get(ScheduledTransaction, schedule["id"]) is None
        deleted = db.query(ScheduledTransactionRevision).filter_by(action="deleted").one()
        assert db.query(WorkspaceCommandReceipt).one().resource_id == deleted.id
    assert client.delete(path, headers=auth(owner_token)).status_code == 404


@pytest.mark.parametrize("changed", ["memo", "pause", "realization"])
def test_reviewed_schedule_deletion_refuses_changed_plan(client, owner_token, session_factory, monkeypatch, changed):
    budget, _, _, path, schedule, request = reviewed_delete(client, owner_token, session_factory)
    if changed == "realization":
        freeze_today(monkeypatch, date(2099, 1, 1), planning_routes)
        realized = client.post(path + "/realize", headers=auth(owner_token))
        assert realized.status_code == 200, realized.text
    else:
        with session_factory() as db:
            current = db.get(ScheduledTransaction, schedule["id"])
            if changed == "memo": current.memo = "Edited elsewhere"
            else: current.is_active = False
            db.commit()
    transactions = f"/api/v1/budgets/{budget['id']}/transactions"
    actuals = client.get(transactions, headers=auth(owner_token)).json()
    assert client.delete(path, **request).status_code == 409
    with session_factory() as db:
        assert db.get(ScheduledTransaction, schedule["id"]) is not None
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(ScheduledTransactionRevision).filter_by(action="deleted").count() == 0
    assert client.get(transactions, headers=auth(owner_token)).json() == actuals


@pytest.mark.parametrize("change", ["revision", "kind", "history", "target", "missing_revision", "invalid_uuid"])
def test_schedule_delete_identity_and_observation_fail_closed(client, owner_token, session_factory, change):
    _, _, _, path, _, request = reviewed_delete(client, owner_token, session_factory)
    if change == "missing_revision":
        request.pop("params")
        assert client.delete(path, **request).status_code == 422
        return
    if change == "invalid_uuid":
        request["headers"]["X-Planning-Operation-ID"] = "not-a-uuid"
        assert client.delete(path, **request).status_code == 422
        return
    assert client.delete(path, **request).status_code == 204
    with session_factory() as db:
        if change == "kind": db.query(WorkspaceCommandReceipt).one().command_kind = "schedule_edit"
        if change == "history": db.query(ScheduledTransactionRevision).filter_by(action="deleted").delete()
        db.commit()
    if change == "revision": request["params"]["expected_revision"] = "v1:" + "a" * 64
    if change == "target": path += "-other"
    assert client.delete(path, **request).status_code == (404 if change == "history" else 409)


@pytest.mark.parametrize("revoked", ["capability", "account", "category"])
def test_deleted_schedule_acknowledgement_checks_retained_resource_scope(client, owner_token, session_factory, revoked):
    budget, account, category, path, _, request = reviewed_delete(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    caps = ["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], caps)
    request["headers"] = {**auth(token), "X-Planning-Operation-ID": str(uuid4())}
    assert client.delete(path, **request).status_code == 204
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": caps if revoked != "capability" else caps[:-1],
        "restrict_accounts": True, "account_ids": [] if revoked == "account" else [account["id"]],
        "restrict_categories": True, "category_ids": [] if revoked == "category" else [category["id"]],
    }).status_code == 200
    assert client.delete(path, **request).status_code in {403, 404}


def test_failed_deletion_commit_preserves_schedule_and_removes_receipt(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, schedule, request = reviewed_delete(client, owner_token, session_factory)
    commit = Session.commit
    def fail(db): raise RuntimeError("Simulated deletion publication failure")
    monkeypatch.setattr(Session, "commit", fail)
    with pytest.raises(RuntimeError, match="publication failure"):
        client.delete(path, **request)
    monkeypatch.setattr(Session, "commit", commit)
    with session_factory() as db:
        assert db.get(ScheduledTransaction, schedule["id"]) is not None
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(ScheduledTransactionRevision).filter_by(action="deleted").count() == 0
    assert client.delete(path, **request).status_code == 204
