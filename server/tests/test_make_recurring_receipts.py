from uuid import uuid4
from datetime import date

import pytest

from app.models import ScheduledTransaction, Transaction, TransactionChange, WorkspaceCommandReceipt
from .conftest import auth, freeze_today
from app import budgeting_routes
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child
from .test_scheduled_transactions_contract import grant_planner


def setup(client, token, factory):
    budget = create_budget(client, token, factory)
    account, category = create_budget_structure(client, token, budget["id"])
    original = record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-1234)
    path = f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/schedule"
    body = dict(recurrence_unit="months", next_date="2099-01-01", expected_revision=original["revision"], mutation_operation_id=str(uuid4()))
    return path, body, original


def test_make_recurring_retry_creates_one_schedule_and_audit_without_actual_mutation(client, owner_token, session_factory):
    path, body, original = setup(client, owner_token, session_factory)
    first = client.post(path, headers=auth(owner_token), json=body)
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == retry.status_code == 201, retry.text
    assert first.json() == retry.json()
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(TransactionChange).filter_by(action="schedule_created").count() == 1
        assert db.query(Transaction).count() == 1
        assert db.get(Transaction, original["id"]).amount_minor == -1234


@pytest.mark.parametrize("changed", ["body", "source", "deleted", "kind"])
def test_recurring_identity_and_observation_fail_closed(client, owner_token, session_factory, changed):
    path, body, original = setup(client, owner_token, session_factory)
    if changed == "source":
        with session_factory() as db:
            db.get(Transaction, original["id"]).memo = "Changed since review"
            db.commit()
        assert client.post(path, headers=auth(owner_token), json=body).status_code == 409
        with session_factory() as db:
            assert db.query(ScheduledTransaction).count() == db.query(WorkspaceCommandReceipt).count() == 0
        return
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201
    with session_factory() as db:
        if changed == "deleted": db.delete(db.get(ScheduledTransaction, first.json()["id"]))
        if changed == "kind": db.query(WorkspaceCommandReceipt).one().command_kind = "schedule_create"
        db.commit()
    if changed == "body": body["next_date"] = "2099-02-01"
    assert client.post(path, headers=auth(owner_token), json=body).status_code == (404 if changed == "deleted" else 409)


@pytest.mark.parametrize("missing", ["expected_revision", "next_date"])
def test_identified_recurring_requires_captured_template_and_date(client, owner_token, session_factory, missing):
    path, body, _ = setup(client, owner_token, session_factory)
    body.pop(missing)
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 422


def test_recurring_acknowledgement_does_not_rebuild_from_later_template(client, owner_token, session_factory):
    path, body, original = setup(client, owner_token, session_factory)
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201
    with session_factory() as db:
        db.get(Transaction, original["id"]).memo = "Later source edit"
        schedule = db.get(ScheduledTransaction, first.json()["id"])
        schedule.is_active = False
        db.commit()
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert retry.status_code == 201 and retry.json()["is_active"] is False
    assert retry.json()["memo"] == first.json()["memo"]


def test_identified_recurring_date_is_not_silently_advanced_when_replay_is_late(client, owner_token, session_factory, monkeypatch):
    path, body, _ = setup(client, owner_token, session_factory)
    freeze_today(monkeypatch, date(2099, 2, 1), budgeting_routes)
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 409
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == db.query(WorkspaceCommandReceipt).count() == 0


@pytest.mark.parametrize("revoked", ["capability", "account", "category"])
def test_recurring_receipt_never_bypasses_current_authorization(client, owner_token, session_factory, revoked):
    path, body, original = setup(client, owner_token, session_factory)
    budget_id = original["budget_id"]
    user_id, token = add_child(session_factory, client)
    capabilities = ["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"]
    grant_planner(client, owner_token, budget_id, user_id, original["account_id"], [original["category_id"]], capabilities)
    assert client.post(path, headers=auth(token), json=body).status_code == 201
    assert client.put(f"/api/v1/budgets/{budget_id}/access/{user_id}", headers=auth(owner_token), json={
        "capabilities": capabilities if revoked != "capability" else capabilities[:-1],
        "restrict_accounts": True, "account_ids": [] if revoked == "account" else [original["account_id"]],
        "restrict_categories": True, "category_ids": [] if revoked == "category" else [original["category_id"]],
    }).status_code == 200
    assert client.post(path, headers=auth(token), json=body).status_code in {403, 404}
    with session_factory() as db:
        assert db.query(ScheduledTransaction).count() == db.query(WorkspaceCommandReceipt).count() == 1
