from uuid import uuid4
import pytest

from app.models import Account, Reconciliation, Transaction, TransactionChange, User, WorkspaceCommandReceipt
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


@pytest.mark.parametrize("adjustment", [0, 50])
def test_reconciliation_retry_acknowledges_history_once_without_reverting_later_state(client, owner_token, session_factory, adjustment):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, is_cleared=True)
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile"
    body = {"statement_balance_minor": -100 + adjustment, "expected_cleared_balance_minor": -100,
            "through_date": "2026-09-04", "create_adjustment": adjustment != 0,
            "adjustment_reason": "Reviewed adjustment", "mutation_operation_id": str(uuid4())}
    first = client.post(path, headers=auth(owner_token), json=body)
    assert first.status_code == 200, first.text
    assert first.json()["adjustment_amount_minor"] == adjustment
    with session_factory() as db:
        history = db.query(TransactionChange).count()
        assert db.query(Reconciliation).count() == 1
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.get(Transaction, row["id"]).is_reconciled
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=200, is_cleared=True)
    later_balance = 100 + adjustment
    later = client.post(path, headers=auth(owner_token), json={"statement_balance_minor": later_balance,
        "expected_cleared_balance_minor": later_balance, "through_date": "2026-09-05"})
    assert later.status_code == 200, later.text
    with session_factory() as db:
        history = db.query(TransactionChange).count()
        reconciled_at = db.get(Account, account["id"]).reconciled_at
    replay = client.post(path, headers=auth(owner_token), json=body)
    assert replay.status_code == 200 and replay.json() == first.json()
    with session_factory() as db:
        assert db.query(Reconciliation).count() == 2
        assert db.query(TransactionChange).count() == history
        assert db.query(Transaction).filter_by(payee_name="Reconciliation adjustment").count() == (1 if adjustment else 0)
        current = db.get(Account, account["id"])
        assert current.reconciled_balance_minor == later_balance
        assert current.reconciled_at == reconciled_at
    assert client.post(path, headers=auth(owner_token), json={**body, "adjustment_reason": "Changed identity"}).status_code == 409
    assert client.post(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409


def test_identified_reconciliation_requires_observation_and_rejects_stale_without_effects(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile"
    body = {"statement_balance_minor": 0, "through_date": "2026-09-04", "mutation_operation_id": str(uuid4())}
    assert client.post(path, headers=auth(owner_token), json=body).status_code == 422
    assert client.post(path, headers=auth(owner_token), json={**body, "expected_cleared_balance_minor": 1}).status_code == 409
    with session_factory() as db:
        assert db.query(Reconciliation).count() == 0
        assert db.query(WorkspaceCommandReceipt).count() == 0
        assert db.query(TransactionChange).count() == 0


@pytest.mark.parametrize("restriction", ["account", "capability"])
def test_reconciliation_receipt_rechecks_current_authorization(client, owner_token, session_factory, restriction):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["reconcile_account", "view_budget", "view_transactions"],
              "restrict_accounts": False, "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile"
    body = {"statement_balance_minor": 0, "expected_cleared_balance_minor": 0,
            "through_date": "2026-09-04", "mutation_operation_id": str(uuid4())}
    assert client.post(path, headers=auth(token), json=body).status_code == 200
    if restriction == "account":
        access["restrict_accounts"] = True
    else:
        access["capabilities"].remove("reconcile_account")
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    response = client.post(path, headers=auth(token), json=body)
    assert response.status_code == (404 if restriction == "account" else 403), response.text
    with session_factory() as db:
        assert db.query(Reconciliation).count() == 1
        assert db.query(WorkspaceCommandReceipt).count() == 1
