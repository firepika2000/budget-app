from uuid import uuid4
import pytest

from app.models import Transaction, TransactionChange, WorkspaceCommandReceipt, User
from .conftest import auth
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def transfer_fixture(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    checking, _ = create_budget_structure(client, token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(token),
                          json={"name": "Savings", "account_type": "savings"}).json()
    path = f"/api/v1/budgets/{budget['id']}/transfers"
    body = {"source_account_id": checking["id"], "destination_account_id": savings["id"],
            "amount_minor": 100, "occurred_on": "2026-09-04"}
    response = client.post(path, headers=auth(token), json=body)
    assert response.status_code == 201, response.text
    transfer = response.json()
    body.update(mutation_operation_id=str(uuid4()), memo="Observed draft",
                expected_revisions={transfer[leg]["id"]: transfer[leg]["revision"] for leg in ("source", "destination")})
    return f"{path}/{transfer['transfer_id']}", body, transfer


def test_identified_transfer_edit_acknowledges_without_reverting_later_state(client, owner_token, session_factory):
    path, body, transfer = transfer_fixture(client, owner_token, session_factory)
    body["amount_minor"] = 9007199254740993
    first = client.put(path, headers=auth(owner_token), json=body)
    assert first.status_code == 200, first.text
    assert first.json()["source"]["amount_minor"] == -9007199254740993
    assert client.put(path, headers=auth(owner_token), json=body).json() == first.json()
    with session_factory() as db:
        assert db.query(TransactionChange).count() == 2
        assert db.query(WorkspaceCommandReceipt).count() == 1
        for leg in db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"]):
            leg.memo = "Later state"
            leg.is_reconciled = True
        db.commit()
    replay = client.put(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 200, replay.text
    assert replay.json()["source"]["memo"] == "Later state"
    assert replay.json()["destination"]["is_reconciled"]
    assert client.put(path, headers=auth(owner_token), json={**body, "memo": "Identity reuse"}).status_code == 409
    assert client.put(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    with session_factory() as db:
        assert db.query(TransactionChange).count() == 2


@pytest.mark.parametrize("leg", ["source", "destination"])
def test_either_stale_transfer_leg_rejects_entire_edit(client, owner_token, session_factory, leg):
    path, body, transfer = transfer_fixture(client, owner_token, session_factory)
    with session_factory() as db:
        db.get(Transaction, transfer[leg]["id"]).memo = "Changed elsewhere"
        db.commit()
    assert client.put(path, headers=auth(owner_token), json=body).status_code == 409
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(TransactionChange).count() == 0
        assert db.get(Transaction, transfer["source"]["id"]).amount_minor == -100
        assert db.get(Transaction, transfer["destination"]["id"]).amount_minor == 100


@pytest.mark.parametrize("observation", [None, {}, {"wrong": "v1:" + "0" * 64},
                                         {"wrong": "v1:" + "0" * 64, "other": "v1:" + "0" * 64}])
def test_transfer_edit_requires_exact_two_leg_observation(client, owner_token, session_factory, observation):
    path, body, _ = transfer_fixture(client, owner_token, session_factory)
    body["expected_revisions"] = observation
    assert client.put(path, headers=auth(owner_token), json=body).status_code == 422
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(TransactionChange).count() == 0


@pytest.mark.parametrize("restriction", ["account", "capability"])
def test_transfer_edit_receipt_rechecks_current_authority(client, owner_token, session_factory, restriction):
    path, body, transfer = transfer_fixture(client, owner_token, session_factory)
    budget_id = path.split("/")[4]
    token = add_member(session_factory, client, "contribute", budget_id)
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
        for leg in db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"]):
            leg.created_by_user_id = member
        db.commit()
    # Observe the newly owned legs rather than submit an already stale draft.
    with session_factory() as db:
        from app.schemas import TransactionResponse
        body["expected_revisions"] = {leg.id: TransactionResponse.model_validate(leg).revision
            for leg in db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"])}
    access = {"capabilities": ["edit_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget_id}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    assert client.put(path, headers=auth(token), json=body).status_code == 200
    if restriction == "account":
        access.update(restrict_accounts=True, account_ids=[body["source_account_id"]])
    else:
        access["capabilities"].remove("edit_transaction")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    response = client.put(path, headers=auth(token), json=body)
    assert response.status_code == (404 if restriction == "account" else 403), response.text
    assert "Observed draft" not in response.text
    with session_factory() as db:
        assert db.query(TransactionChange).count() == 2
        assert db.query(WorkspaceCommandReceipt).count() == 1
