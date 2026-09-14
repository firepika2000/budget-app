from app.models import Payee, Transaction, TransactionChange

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def test_payee_identity_normalization_default_and_transaction_link(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "  Corner   Market  ", "default_category_id": category["id"],
    })
    assert created.status_code == 201
    payee = created.json()
    assert payee["display_name"] == "Corner Market"
    assert payee["default_category_id"] == category["id"]
    duplicate = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "corner market",
    })
    assert duplicate.status_code == 409

    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": payee["id"],
        "payee_name": "client cannot spoof this", "amount_minor": -1234, "occurred_on": "2026-09-04",
    })
    assert transaction.status_code == 201
    assert transaction.json()["payee_id"] == payee["id"]
    assert transaction.json()["payee_name"] == "Corner Market"
    listed = client.get(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token)).json()
    assert listed[0]["transaction_count"] == 1
    assert listed[0]["net_amount_minor"] == -1234


def test_payee_alias_rename_archive_and_merge_preserve_transaction_audit(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    source = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart Store"}).json()
    destination = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart"}).json()
    alias = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token), json={"display_name": "WM SUPERCENTER"})
    assert alias.status_code == 201
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": source["id"],
        "amount_minor": -2500, "occurred_on": "2026-09-04",
    }).json()
    merged = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
    assert merged.status_code == 200
    assert merged.json()["transaction_count"] == 1
    assert merged.json()["aliases"][0]["display_name"] == "WM SUPERCENTER"
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == destination["id"]
        assert row.payee_name == "Walmart"
        source_row = db.get(Payee, source["id"])
        assert source_row.is_archived is True
        assert source_row.merged_into_payee_id == destination["id"]
        change = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_merged").one()
        assert change.actor_user_id is not None


def test_system_transaction_names_do_not_require_payee_identity(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={
        "name": "Checking", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 10000,
    }).json()
    transactions = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert transactions[0]["payee_name"] == "Starting Balance"
    assert transactions[0]["payee_id"] is None
    assert account["id"] == transactions[0]["account_id"]
