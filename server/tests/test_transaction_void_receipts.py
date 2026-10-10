from uuid import uuid4

import pytest

from app.models import CreditCardReserveEvent, Transaction, TransactionChange, User, WorkspaceCommandReceipt
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def fixture(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    account, category = create_budget_structure(client, token, budget["id"])
    transaction = record(client, token, budget["id"], account_id=account["id"], category_id=category["id"],
                         amount_minor=-9007199254740993, memo="Original", tags=["keep"], flag="orange")
    path = f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}/void"
    body = {"reason": "Reviewed duplicate", "expected_revision": transaction["revision"],
            "mutation_operation_id": str(uuid4())}
    return budget, account, transaction, path, body


def test_identified_void_retry_acknowledges_one_reversal_and_preserves_later_state(client, owner_token, session_factory):
    _, _, original, path, body = fixture(client, owner_token, session_factory)
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 201, first.text
    reversal = first.json()
    assert reversal["amount_minor"] == 9007199254740993
    assert reversal["tags"] == ["keep"] and reversal["flag"] == "orange"
    with session_factory() as db:
        changes = db.query(TransactionChange).count()
        db.get(Transaction, reversal["id"]).is_reconciled = True
        db.commit()
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert retry.status_code == 201 and retry.json()["id"] == reversal["id"]
    assert retry.json()["is_reconciled"] is True
    with session_factory() as db:
        assert db.query(Transaction).filter_by(reversal_of_transaction_id=original["id"]).count() == 1
        assert db.query(TransactionChange).count() == changes
        assert db.query(WorkspaceCommandReceipt).count() == 1
    assert client.post(path, headers=auth(owner_token), json={**body, "reason": "Different consent"}).status_code == 409
    assert client.post(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409


@pytest.mark.parametrize("revision", [None, "invalid", "v1:" + "0" * 64])
def test_identified_void_rejects_missing_malformed_or_stale_observation(client, owner_token, session_factory, revision):
    _, _, original, path, body = fixture(client, owner_token, session_factory)
    body["expected_revision"] = revision
    with session_factory() as db:
        changes = db.query(TransactionChange).count()
    response = client.post(path, headers=auth(owner_token), json=body)
    assert response.status_code == (409 if revision and revision.startswith("v1:") else 422), response.text
    with session_factory() as db:
        assert db.get(Transaction, original["id"]).status == "posted"
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(TransactionChange).count() == changes


@pytest.mark.parametrize("restriction", ["account", "category", "capability", "ownership"])
def test_void_acknowledgement_rechecks_current_authority(client, owner_token, session_factory, restriction):
    budget, account, original, path, body = fixture(client, owner_token, session_factory)
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
        db.get(Transaction, original["id"]).created_by_user_id = member
        db.commit()
        from app.schemas import TransactionResponse
        body["expected_revision"] = TransactionResponse.model_validate(db.get(Transaction, original["id"])).revision
    access = {"capabilities": ["delete_transaction", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    assert client.post(path, headers=auth(token), json=body).status_code == 201
    if restriction == "ownership":
        with session_factory() as db:
            db.get(Transaction, original["id"]).created_by_user_id = db.query(User).filter_by(email="owner@example.com").one().id
            db.commit()
    else:
        if restriction == "account":
            access.update(restrict_accounts=True, account_ids=[])
        elif restriction == "category":
            access.update(restrict_categories=True, category_ids=[])
        else:
            access["capabilities"].remove("delete_transaction")
        assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    retry = client.post(path, headers=auth(token), json=body)
    assert retry.status_code == (404 if restriction in {"account", "category"} else 403), retry.text
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(Transaction).filter_by(reversal_of_transaction_id=original["id"]).count() == 1


def test_void_receipt_cannot_be_reused_for_another_target(client, owner_token, session_factory):
    budget, account, _, path, body = fixture(client, owner_token, session_factory)
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 201
    other = record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=1)
    response = client.post(path.replace(path.split("/")[-2], other["id"]), headers=auth(owner_token),
                           json={**body, "expected_revision": other["revision"]})
    assert response.status_code == 409
    with session_factory() as db:
        assert db.get(Transaction, other["id"]).status == "posted"
        assert db.query(WorkspaceCommandReceipt).count() == 1


def test_void_cannot_reuse_a_bulk_command_identity(client, owner_token, session_factory):
    budget, _, original, path, body = fixture(client, owner_token, session_factory)
    response = client.post(f"/api/v1/budgets/{budget['id']}/transactions/bulk", headers=auth(owner_token), json={
        "transaction_ids": [original["id"]], "action": "set_cleared", "cleared": True,
        "mutation_operation_id": body["mutation_operation_id"], "expected_revisions": {original["id"]: original["revision"]},
    })
    assert response.status_code == 200, response.text
    with session_factory() as db:
        from app.schemas import TransactionResponse
        body["expected_revision"] = TransactionResponse.model_validate(db.get(Transaction, original["id"])).revision
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 409
    with session_factory() as db:
        assert db.get(Transaction, original["id"]).status == "posted"
        assert db.query(WorkspaceCommandReceipt).count() == 1


def test_actual_metadata_change_rejects_reviewed_void_without_financial_effects(client, owner_token, session_factory):
    _, _, original, path, body = fixture(client, owner_token, session_factory)
    with session_factory() as db:
        db.get(Transaction, original["id"]).memo = "Changed since review"
        db.commit()
        changes = db.query(TransactionChange).count()
    response = client.post(path, headers=auth(owner_token), json=body)
    assert response.status_code == 409
    with session_factory() as db:
        transaction = db.get(Transaction, original["id"])
        assert transaction.status == "posted" and transaction.memo == "Changed since review"
        assert transaction.amount_minor == -9007199254740993
        assert db.query(Transaction).filter_by(reversal_of_transaction_id=original["id"]).count() == 0
        assert db.query(TransactionChange).count() == changes
        assert db.query(WorkspaceCommandReceipt).count() == 0


def test_identified_card_void_retry_releases_payment_reserve_once(client, owner_token, session_factory):
    from datetime import date
    from .test_allocation_ledger import fund
    from .test_credit_cards import create_credit_card
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=50000)
    response = client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
                          headers=auth(owner_token), json={"month": date.today().replace(day=1).isoformat(), "assigned_minor": 10000})
    assert response.status_code == 200
    original = record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"],
                      amount_minor=-5000, occurred_on=date.today().isoformat())
    path = f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}/void"
    body = {"reason": "Duplicate", "expected_revision": original["revision"], "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(owner_token), json=body)
    retry = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == retry.status_code == 201
    assert first.json()["id"] == retry.json()["id"]
    with session_factory() as db:
        events = db.query(CreditCardReserveEvent).filter_by(credit_account_id=card["id"]).all()
        assert len(events) == 2 and sum(item.amount_minor for item in events) == 0
