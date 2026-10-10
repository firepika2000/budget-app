from uuid import uuid4
import pytest

from app.models import CreditCardReserveEvent, Transaction, WorkspaceCommandReceipt, User
from .conftest import auth
from .test_budgeting_api import add_member, create_budget, create_budget_structure


@pytest.mark.parametrize("account_type", ["savings", "credit"])
def test_transfer_creation_retry_preserves_both_legs_and_later_state(client, owner_token, session_factory, account_type):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Destination", "account_type": account_type}).json()
    path = f"/api/v1/budgets/{budget['id']}/transfers"
    body = {"source_account_id": checking["id"], "destination_account_id": savings["id"],
            "amount_minor": 9007199254740993, "occurred_on": "2026-09-04",
            "mutation_operation_id": str(uuid4())}
    if account_type == "credit":
        # Credit-to-cash uses the existing payment-reversal reserve path;
        # unfunded cash-to-card payments must continue to be rejected.
        body.update(source_account_id=savings["id"], destination_account_id=checking["id"])
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201, first.text
    replay = client.post(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 201 and replay.json() == first.json()
    with session_factory() as db:
        assert db.query(Transaction).filter_by(transfer_id=first.json()["transfer_id"]).count() == 2
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(CreditCardReserveEvent).filter_by(transfer_id=first.json()["transfer_id"]).count() == (1 if account_type == "credit" else 0)
        for leg in db.query(Transaction).filter_by(transfer_id=first.json()["transfer_id"]):
            leg.memo = "Later change"
            leg.is_reconciled = True
        db.commit()
    replay = client.post(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 201, replay.text
    assert replay.json()["source"]["memo"] == "Later change"
    assert replay.json()["destination"]["is_reconciled"]
    assert client.post(path, headers=auth(owner_token), json={**body, "amount_minor": 1}).status_code == 409
    with session_factory() as db:
        assert db.query(CreditCardReserveEvent).filter_by(transfer_id=first.json()["transfer_id"]).count() == (1 if account_type == "credit" else 0)


def test_deleted_accepted_transfer_is_not_recreated(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Savings", "account_type": "savings"}).json()
    path = f"/api/v1/budgets/{budget['id']}/transfers"
    body = {"source_account_id": checking["id"], "destination_account_id": savings["id"],
            "amount_minor": 100, "occurred_on": "2026-09-04", "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201, first.text
    assert client.delete(f"{path}/{first.json()['transfer_id']}", headers=auth(owner_token)).status_code == 204
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 404
    with session_factory() as db:
        assert db.query(Transaction).filter_by(transfer_id=first.json()["transfer_id"]).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("restriction", ["account", "capability"])
def test_transfer_receipt_rechecks_current_authorization(client, owner_token, session_factory, restriction):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Savings", "account_type": "savings"}).json()
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["create_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    path = f"/api/v1/budgets/{budget['id']}/transfers"
    body = {"source_account_id": checking["id"], "destination_account_id": savings["id"],
            "amount_minor": 100, "occurred_on": "2026-09-04", "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(token), json=body)
    assert first.status_code == 201, first.text
    if restriction == "account":
        access.update(restrict_accounts=True, account_ids=[checking["id"]])
    else:
        access["capabilities"].remove("create_transaction")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    replay = client.post(path, headers=auth(token), json=body)
    assert replay.status_code == (422 if restriction == "account" else 403), replay.text
    assert first.json()["transfer_id"] not in replay.text
    with session_factory() as db:
        assert db.query(Transaction).filter_by(transfer_id=first.json()["transfer_id"]).count() == 2
