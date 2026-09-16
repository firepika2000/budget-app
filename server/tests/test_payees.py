from app.models import Budget, Payee, PayeeAlias, Transaction, TransactionChange, User

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


def test_free_text_transaction_resolves_or_creates_canonical_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "  Metadata   test ",
        "amount_minor": -200, "occurred_on": "2026-09-15",
    })
    assert created.status_code == 201, created.text
    transaction = created.json()
    assert transaction["payee_id"] is not None
    assert transaction["payee_name"] == "Metadata test"
    with session_factory() as db:
        payee = db.get(Payee, transaction["payee_id"])
        assert payee.display_name == "Metadata test"
        db.add(PayeeAlias(payee_id=payee.id, display_name="QA merchant", name_key="qa merchant", created_by_user_id=payee.created_by_user_id))
        db.commit()
    via_alias = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "qa MERCHANT",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    }).json()
    assert via_alias["payee_id"] == transaction["payee_id"]
    assert via_alias["payee_name"] == "Metadata test"


def test_payee_search_is_bounded_stable_alias_aware_and_paginated(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    with session_factory() as db:
        household_id = db.get(Budget, budget["id"]).household_id
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        values = [Payee(household_id=household_id, display_name=f"Merchant {index:05d}", name_key=f"merchant {index:05d}", created_by_user_id=owner_id) for index in range(1500)]
        db.add_all(values); db.flush()
        db.add(PayeeAlias(payee_id=values[1499].id, display_name="Needle Alias", name_key="needle alias", created_by_user_id=owner_id))
        db.commit()
        alias_payee_id = values[1499].id
    first = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20", headers=auth(owner_token))
    assert first.status_code == 200, first.text
    assert len(first.json()["items"]) == 20
    assert first.json()["next_cursor"] is not None
    second = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20&cursor={first.json()['next_cursor']}", headers=auth(owner_token))
    assert second.status_code == 200
    assert not ({item["id"] for item in first.json()["items"]} & {item["id"] for item in second.json()["items"]})
    alias = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=needle&limit=20", headers=auth(owner_token)).json()
    assert [item["id"] for item in alias["items"]] == [alias_payee_id]
    assert alias["next_cursor"] is None
    invalid = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?cursor=not-a-cursor", headers=auth(owner_token))
    assert invalid.status_code == 422


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
    renamed = client.put(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}", headers=auth(owner_token), json={
        "display_name": "Walmart Store Renamed", "is_archived": False,
    })
    assert renamed.status_code == 200, renamed.text
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == source["id"]
        assert row.payee_name == "Walmart Store Renamed"
        rename = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_renamed").one()
        assert '"payee_name": "Walmart Store"' in rename.before_json
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


def test_free_text_does_not_resurrect_archived_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Retired Merchant",
    }).json()
    archived = client.put(f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}", headers=auth(owner_token), json={
        "display_name": "Retired Merchant", "is_archived": True,
    })
    assert archived.status_code == 200
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "retired merchant",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert transaction.status_code == 422
    assert transaction.json()["detail"] == "Invalid payee"


def test_system_transaction_names_do_not_require_payee_identity(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={
        "name": "Checking", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 10000,
    }).json()
    transactions = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert transactions[0]["payee_name"] == "Starting Balance"
    assert transactions[0]["payee_id"] is None
    assert account["id"] == transactions[0]["account_id"]
