from uuid import uuid4

import pytest

from app.models import Transaction, TransactionChange, WorkspaceCommandReceipt, User
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure, add_member


def setup_transfer(client, token, factory):
    budget = create_budget(client, token, factory)
    source, _ = create_budget_structure(client, token, budget["id"])
    destination = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(token),
                              json={"name": "Savings", "account_type": "savings"}).json()
    path = f"/api/v1/budgets/{budget['id']}/transfers"
    response = client.post(path, headers=auth(token), json={"source_account_id": source["id"],
        "destination_account_id": destination["id"], "amount_minor": 9007199254740993,
        "occurred_on": "2026-09-04"})
    assert response.status_code == 201, response.text
    transfer = response.json()
    body = {"mutation_operation_id": str(uuid4()), "expected_revisions": {
        transfer[side]["id"]: transfer[side]["revision"] for side in ("source", "destination")}}
    return path + "/" + transfer["transfer_id"], transfer, body


def test_reviewed_transfer_delete_acknowledges_once(client, owner_token, session_factory):
    path, transfer, body = setup_transfer(client, owner_token, session_factory)
    for _ in range(2):
        response = client.request("DELETE", path, headers=auth(owner_token), json=body)
        assert response.status_code == 204, response.text
    assert client.delete(path, headers=auth(owner_token)).status_code == 404
    changed = {**body, "expected_revisions": {key: "v1:" + "0" * 64 for key in body["expected_revisions"]}}
    assert client.request("DELETE", path, headers=auth(owner_token), json=changed).status_code == 409
    with session_factory() as db:
        assert db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"]).count() == 0
        assert db.query(TransactionChange).filter_by(action="deleted").count() == 2
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transfer_delete").count() == 1
        db.query(TransactionChange).filter_by(action="deleted").delete()
        db.commit()
    assert client.request("DELETE", path, headers=auth(owner_token), json=body).status_code == 409


@pytest.mark.parametrize("protection", ["stale", "reconciled", "missing_leg", "invalid_revision"])
def test_transfer_delete_rejects_unreviewed_or_protected_legs(client, owner_token, session_factory, protection):
    path, transfer, body = setup_transfer(client, owner_token, session_factory)
    if protection in {"stale", "reconciled"}:
        with session_factory() as db:
            leg = db.get(Transaction, transfer["destination"]["id"])
            if protection == "stale": leg.memo = "Changed after review"
            else: leg.is_reconciled = True
            db.commit()
    elif protection == "missing_leg": body["expected_revisions"].pop(transfer["source"]["id"])
    else: body["expected_revisions"][transfer["source"]["id"]] = "invalid"
    response = client.request("DELETE", path, headers=auth(owner_token), json=body)
    assert response.status_code == (409 if protection in {"stale", "reconciled"} else 422), response.text
    with session_factory() as db:
        assert db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"]).count() == 2
        assert db.query(WorkspaceCommandReceipt).filter_by(command_kind="transfer_delete").count() == 0


@pytest.mark.parametrize("restriction", ["account", "capability", "ownership"])
def test_deleted_transfer_retry_rechecks_current_authority(client, owner_token, session_factory, restriction):
    path, transfer, body = setup_transfer(client, owner_token, session_factory)
    budget_id = path.split("/")[4]
    token = add_member(session_factory, client, "contribute", budget_id)
    from app.schemas import TransactionResponse
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
        for leg in db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"]):
            if restriction != "ownership": leg.created_by_user_id = member
        db.commit()
        body["expected_revisions"] = {leg.id: TransactionResponse.model_validate(leg).revision
            for leg in db.query(Transaction).filter_by(transfer_id=transfer["transfer_id"])}
    access = {"capabilities": ["delete_transaction", "view_budget", "view_transactions", "manage_budget_structure"],
        "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget_id}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    assert client.request("DELETE", path, headers=auth(token), json=body).status_code == 204
    if restriction == "account": access.update(restrict_accounts=True, account_ids=[])
    elif restriction == "capability": access["capabilities"].remove("delete_transaction")
    else: access["capabilities"].remove("manage_budget_structure")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    response = client.request("DELETE", path, headers=auth(token), json=body)
    assert response.status_code == (404 if restriction == "account" else 403), response.text
