from uuid import uuid4
from datetime import date

import pytest
from sqlalchemy.orm import Session

from app.models import ScheduledTransaction, ScheduledTransactionRevision, WorkspaceCommandReceipt
from .conftest import auth, freeze_today
from app import planning_routes
from .test_schedule_creation_receipts import setup
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def reviewed_edit(client, token, factory):
    budget, account, category, path, body, _ = setup(client, token, factory)
    created = client.post(path, headers=auth(token), json=body)
    assert created.status_code == 201, created.text
    item = created.json()
    assert len(item["revision"]) == 67
    edit = {**body, "memo": "Reviewed edit", "expected_revision": item["revision"], "mutation_operation_id": str(uuid4())}
    return budget, account, category, f"{path}/{item['id']}", edit, item


def test_identified_schedule_edit_retry_preserves_later_pause_and_actuals(client, owner_token, session_factory):
    budget, _, _, path, body, original = reviewed_edit(client, owner_token, session_factory)
    root = f"/api/v1/budgets/{budget['id']}"
    observations = {suffix: client.get(root + suffix, headers=auth(owner_token)).json()
                    for suffix in ["/transactions", "/months/2099-01-01"]}
    first = client.put(path, headers=auth(owner_token), json=body)
    retry = client.put(path, headers=auth(owner_token), json=body)
    assert first.status_code == retry.status_code == 200, retry.text
    assert first.json() == retry.json()
    assert first.json()["revision"] != original["revision"]
    later = {k: v for k, v in body.items() if k not in {"expected_revision", "mutation_operation_id"}}
    later.update(memo="Later edit", is_active=False)
    assert client.put(path, headers=auth(owner_token), json=later).status_code == 200
    ack = client.put(path, headers=auth(owner_token), json=body)
    assert ack.status_code == 200
    assert ack.json()["memo"] == "Later edit" and ack.json()["is_active"] is False
    for suffix, value in observations.items():
        assert client.get(root + suffix, headers=auth(owner_token)).json() == value
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(ScheduledTransactionRevision).filter_by(action="updated").count() == 1
        assert db.query(ScheduledTransaction).one().amount_minor == -9007199254740993


@pytest.mark.parametrize("field,value", [("memo", "Changed elsewhere"), ("is_active", False),
                                        ("next_date", "2099-02-01"), ("remaining_occurrences", 2)])
def test_reviewed_schedule_edit_rejects_changed_schedule_without_overwrite(client, owner_token, session_factory, field, value):
    _, _, _, path, body, original = reviewed_edit(client, owner_token, session_factory)
    with session_factory() as db:
        schedule = db.get(ScheduledTransaction, original["id"])
        if field == "next_date":
            from datetime import date
            value = date.fromisoformat(value)
        setattr(schedule, field, value)
        db.commit()
    response = client.put(path, headers=auth(owner_token), json=body)
    assert response.status_code == 409, response.text
    with session_factory() as db:
        assert db.get(ScheduledTransaction, original["id"]).memo == (value if field == "memo" else "original")
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(ScheduledTransactionRevision).filter_by(action="updated").count() == 0


@pytest.mark.parametrize("change", ["intent", "kind", "deleted", "missing_revision"])
def test_schedule_edit_identity_fails_closed(client, owner_token, session_factory, change):
    _, _, _, path, body, original = reviewed_edit(client, owner_token, session_factory)
    if change == "missing_revision":
        body.pop("expected_revision")
        assert client.put(path, headers=auth(owner_token), json=body).status_code == 422
        return
    assert client.put(path, headers=auth(owner_token), json=body).status_code == 200
    with session_factory() as db:
        if change == "kind": db.query(WorkspaceCommandReceipt).one().command_kind = "schedule_create"
        if change == "deleted": db.delete(db.get(ScheduledTransaction, original["id"]))
        db.commit()
    if change == "intent": body["memo"] = "Different retry"
    assert client.put(path, headers=auth(owner_token), json=body).status_code == (404 if change == "deleted" else 409)


@pytest.mark.parametrize("revoked", ["capability", "account", "category"])
def test_accepted_schedule_edit_retry_checks_current_permissions(client, owner_token, session_factory, revoked):
    budget, account, category, path, body, _ = reviewed_edit(client, owner_token, session_factory)
    user_id, token = add_child(session_factory, client)
    caps = ["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"]
    grant_planner(client, owner_token, budget["id"], user_id, account["id"], [category["id"]], caps)
    assert client.put(path, headers=auth(token), json=body).status_code == 200
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": caps if revoked != "capability" else caps[:-1],
        "restrict_accounts": True, "account_ids": [] if revoked == "account" else [account["id"]],
        "restrict_categories": True, "category_ids": [] if revoked == "category" else [category["id"]],
    }).status_code == 200
    assert client.put(path, headers=auth(token), json=body).status_code in {403, 404}


def test_schedule_edit_receipt_rolls_back_with_failed_commit(client, owner_token, session_factory, monkeypatch):
    _, _, _, path, body, original = reviewed_edit(client, owner_token, session_factory)
    commit = Session.commit
    def failed_commit(db):
        raise RuntimeError("Simulated failed publication")
    monkeypatch.setattr(Session, "commit", failed_commit)
    with pytest.raises(RuntimeError, match="failed publication"):
        client.put(path, headers=auth(owner_token), json=body)
    monkeypatch.setattr(Session, "commit", commit)
    with session_factory() as db:
        assert db.get(ScheduledTransaction, original["id"]).memo == "original"
        assert db.query(WorkspaceCommandReceipt).count() == 0
    assert client.put(path, headers=auth(owner_token), json=body).status_code == 200


@pytest.mark.parametrize("accepted_before_realization", [True, False])
def test_reviewed_edit_never_rewinds_a_realized_schedule(client, owner_token, session_factory, monkeypatch, accepted_before_realization):
    budget, _, _, path, body, _ = reviewed_edit(client, owner_token, session_factory)
    if accepted_before_realization:
        assert client.put(path, headers=auth(owner_token), json=body).status_code == 200
    freeze_today(monkeypatch, date(2099, 1, 1), planning_routes)
    realized = client.post(path + "/realize", headers=auth(owner_token))
    assert realized.status_code == 200, realized.text
    transactions_url = f"/api/v1/budgets/{budget['id']}/transactions"
    actuals = client.get(transactions_url, headers=auth(owner_token)).json()
    assert len(actuals) == 1
    retry = client.put(path, headers=auth(owner_token), json=body)
    assert retry.status_code == (200 if accepted_before_realization else 409), retry.text
    if accepted_before_realization:
        assert retry.json()["next_date"] == "2099-02-01"
        assert retry.json()["last_realized_on"] == "2099-01-01"
    assert client.get(transactions_url, headers=auth(owner_token)).json() == actuals
