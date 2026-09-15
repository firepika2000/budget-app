from app.models import Transaction, TransactionChange

from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def _bulk(client, token, budget_id, transaction_ids, action, **values):
    return client.post(
        f"/api/v1/budgets/{budget_id}/transactions/bulk",
        headers=auth(token),
        json={"transaction_ids": transaction_ids, "action": action, **values},
    )


def test_bulk_metadata_normalizes_and_audits_every_selected_transaction(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, tags=[" Existing "])
    second = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200)

    response = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "add_tags", tags=[" Review ", "review"])
    assert response.status_code == 200, response.text
    assert [row["tags"] for row in response.json()] == [["existing", "review"], ["review"]]
    response = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "set_flag", flag=" BLUE ")
    assert response.status_code == 200
    assert [row["flag"] for row in response.json()] == ["blue", "blue"]
    with session_factory() as db:
        assert db.query(TransactionChange).filter(TransactionChange.transaction_id.in_([first["id"], second["id"]]), TransactionChange.action == "bulk_updated").count() == 4


def test_bulk_rejection_is_atomic_for_missing_or_reconciled_member(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    second = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200)

    missing = _bulk(client, owner_token, budget["id"], [first["id"], "missing"], "set_cleared", cleared=True)
    assert missing.status_code == 404
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in rows if row["id"] == first["id"])["is_cleared"] is False

    with session_factory() as db:
        db.get(Transaction, second["id"]).is_reconciled = True
        db.commit()
    denied = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "set_flag", flag="red")
    assert denied.status_code == 409
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert all(row["flag"] is None for row in rows if row["id"] in {first["id"], second["id"]})


def test_bulk_rejects_system_linked_rows_without_partial_mutation(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    ordinary = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    opening_account = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings", "is_on_budget": True, "starting_balance_minor": 5000},
    ).json()
    opening = next(row for row in client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json() if row["account_id"] == opening_account["id"])
    response = _bulk(client, owner_token, budget["id"], [ordinary["id"], opening["id"]], "set_cleared", cleared=True)
    assert response.status_code == 409
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in rows if row["id"] == ordinary["id"])["is_cleared"] is False


def test_single_transaction_clearing_persists_without_financial_mutation_or_permission_bypass(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transactions = [
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-4321),
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2222, tags=["existing"]),
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-3333, payee_name="Metadata Payee", memo="keep exactly", flag="purple"),
    ]
    def unchanged_metadata(row):
        return {key: value for key, value in row.items() if key != "is_cleared"}

    for transaction in transactions:
        cleared = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=True)
        assert cleared.status_code == 200, cleared.text
        assert cleared.json()[0]["is_cleared"] is True
        assert unchanged_metadata(cleared.json()[0]) == unchanged_metadata(transaction)
        uncleared = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
        assert uncleared.status_code == 200, uncleared.text
        assert uncleared.json()[0]["is_cleared"] is False
        assert unchanged_metadata(uncleared.json()[0]) == unchanged_metadata(transaction)

    transaction = transactions[0]
    assert _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=True).status_code == 200
    persisted = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in persisted if row["id"] == transaction["id"])["is_cleared"] is True

    contributor_token = add_member(session_factory, client, "contribute", budget["id"])
    denied = _bulk(client, contributor_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
    assert denied.status_code == 403
    persisted = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in persisted if row["id"] == transaction["id"])["is_cleared"] is True

    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        row.is_reconciled = True
        db.commit()
    reconciled = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
    assert reconciled.status_code == 409
