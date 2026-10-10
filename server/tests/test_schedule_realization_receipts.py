from datetime import date
from uuid import uuid4
from sqlalchemy.orm import Session

import pytest

from app import planning_routes
from app.models import ScheduledTransaction, ScheduledTransactionRevision, WorkspaceCommandReceipt
from .conftest import auth, freeze_today
from .test_schedule_creation_receipts import setup
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def reviewed_realization(client, token, factory, monkeypatch, recurrence="days"):
    freeze_today(monkeypatch, date(2026, 9, 5), planning_routes)
    budget, _, _, collection, body, headers = setup(client, token, factory)
    body.update(next_date="2026-09-01", recurrence_unit=recurrence, remaining_occurrences=3 if recurrence != "once" else None)
    created = client.post(collection, headers=auth(token), json=body)
    assert created.status_code == 201, created.text
    item = created.json()
    return budget, f"{collection}/{item['id']}", headers, {"expected_revision": item["revision"]}


@pytest.mark.parametrize("recurrence", ["days", "once"])
def test_lost_realization_response_does_not_post_next_overdue_occurrence(client, owner_token, session_factory, monkeypatch, recurrence):
    budget, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch, recurrence)
    first = client.post(path + "/realize", headers=headers, params=params)
    retry = client.post(path + "/realize", headers=headers, params=params)
    assert first.status_code == retry.status_code == 200, retry.text
    assert first.json() == retry.json()
    transactions = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert len(transactions) == 1
    assert transactions[0]["amount_minor"] == -9007199254740993
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1
        event = db.query(ScheduledTransactionRevision).filter_by(action="realized").one()
        if recurrence == "days":
            assert event.before_snapshot["remaining_occurrences"] == 3
            assert event.after_snapshot["remaining_occurrences"] == 2


def test_realization_ack_survives_later_realization_and_schedule_deletion(client, owner_token, session_factory, monkeypatch):
    budget, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch)
    first = client.post(path + "/realize", headers=headers, params=params)
    assert first.status_code == 200, first.text
    assert client.post(path + "/realize", headers=auth(owner_token)).status_code == 200
    assert client.delete(path, headers=auth(owner_token)).status_code == 204
    retry = client.post(path + "/realize", headers=headers, params=params)
    assert retry.status_code == 200 and retry.json() == first.json()
    assert len(client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()) == 2


def test_stale_realization_observation_cannot_post(client, owner_token, session_factory, monkeypatch):
    _, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch)
    with session_factory() as db:
        db.query(ScheduledTransaction).one().memo = "Changed elsewhere"
        db.commit()
    assert client.post(path + "/realize", headers=headers, params=params).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(ScheduledTransactionRevision).filter_by(action="realized").count() == 0


@pytest.mark.parametrize("failure", ["missing_revision", "different_revision", "wrong_kind", "missing_event"])
def test_realization_identity_fails_closed(client, owner_token, session_factory, monkeypatch, failure):
    _, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch)
    if failure == "missing_revision":
        assert client.post(path + "/realize", headers=headers).status_code == 422
        return
    assert client.post(path + "/realize", headers=headers, params=params).status_code == 200
    with session_factory() as db:
        receipt = db.query(WorkspaceCommandReceipt).one()
        if failure == "wrong_kind":
            receipt.command_kind = "schedule_delete"
        if failure == "missing_event":
            receipt.resource_id = str(uuid4())
        db.commit()
    if failure == "different_revision":
        params["expected_revision"] = "v1:" + "0" * 64
    assert client.post(path + "/realize", headers=headers, params=params).status_code == (404 if failure == "missing_event" else 409)


@pytest.mark.parametrize("revoked", ["capability", "account", "category"])
def test_accepted_realization_rechecks_current_authority(client, owner_token, session_factory, monkeypatch, revoked):
    budget, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch)
    with session_factory() as db:
        schedule = db.query(ScheduledTransaction).one()
        account_id, category_id = schedule.account_id, schedule.category_id
    user_id, token = add_child(session_factory, client)
    caps = ["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction"]
    grant_planner(client, owner_token, budget["id"], user_id, account_id, [category_id], caps)
    headers.update(auth(token))
    assert client.post(path + "/realize", headers=headers, params=params).status_code == 200
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": caps if revoked != "capability" else caps[:-1],
        "restrict_accounts": True, "account_ids": [] if revoked == "account" else [account_id],
        "restrict_categories": True, "category_ids": [] if revoked == "category" else [category_id],
    }).status_code == 200
    assert client.post(path + "/realize", headers=headers, params=params).status_code in {403, 404}


def test_failed_realization_commit_leaves_no_receipt_or_posting(client, owner_token, session_factory, monkeypatch):
    _, path, headers, params = reviewed_realization(client, owner_token, session_factory, monkeypatch)
    commit = Session.commit
    def fail(db):
        raise RuntimeError("Simulated failed commit")
    monkeypatch.setattr(Session, "commit", fail)
    with pytest.raises(RuntimeError, match="failed commit"):
        client.post(path + "/realize", headers=headers, params=params)
    monkeypatch.setattr(Session, "commit", commit)
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(ScheduledTransactionRevision).filter_by(action="realized").count() == 0
        assert db.query(ScheduledTransaction).one().remaining_occurrences == 3
    assert client.post(path + "/realize", headers=headers, params=params).status_code == 200
