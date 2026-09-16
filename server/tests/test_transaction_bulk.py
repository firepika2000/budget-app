from app.models import Transaction, TransactionChange, User

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


def test_category_restriction_hides_uncategorized_transaction_from_every_mutation_surface(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    contributor_token = add_member(session_factory, client, "contribute", budget["id"])
    hidden = record(
        client, contributor_token, budget["id"], account_id=account["id"],
        amount_minor=5000, payee_name="Private uncategorized income",
    )
    with session_factory() as db:
        contributor_id = db.query(User.id).filter(User.email == "contribute@example.com").scalar()

    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{contributor_id}",
        headers=auth(owner_token),
        json={
            "capabilities": [
                "view_budget", "view_accounts", "view_categories", "view_transactions",
                "create_transaction", "edit_transaction", "delete_transaction", "manage_planning",
            ],
            "restrict_accounts": True,
            "account_ids": [account["id"]],
            "restrict_categories": True,
            "category_ids": [category["id"]],
        },
    )
    assert profile.status_code == 200, profile.text

    assert _search_ids(client, contributor_token, budget["id"]) == []
    attempts = [
        _bulk(client, contributor_token, budget["id"], [hidden["id"]], "set_flag", flag="red"),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/duplicate",
            headers=auth(contributor_token), json={"occurred_on": "2026-09-10"},
        ),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/void",
            headers=auth(contributor_token), json={"reason": "must remain hidden"},
        ),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/schedule",
            headers=auth(contributor_token),
            json={"next_date": "2026-10-01", "recurrence_unit": "months", "interval_count": 1},
        ),
        client.get(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/attachments",
            headers=auth(contributor_token),
        ),
        client.put(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}",
            headers=auth(contributor_token),
            json={
                "account_id": account["id"], "category_id": category["id"],
                "amount_minor": -100, "occurred_on": "2026-09-10",
                "payee_name": "Attempted disclosure", "memo": "", "is_cleared": False,
                "splits": [], "tags": [],
            },
        ),
        client.delete(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}",
            headers=auth(contributor_token),
        ),
    ]
    assert [response.status_code for response in attempts] == [404] * len(attempts)

    with session_factory() as db:
        unchanged = db.get(Transaction, hidden["id"])
        assert unchanged is not None
        assert unchanged.payee_name == "Private uncategorized income"
        assert unchanged.flag is None
        assert unchanged.status == "posted"


def _search_ids(client, token, budget_id):
    response = client.get(
        f"/api/v1/budgets/{budget_id}/transactions/search", headers=auth(token),
    )
    assert response.status_code == 200, response.text
    return [row["id"] for row in response.json()["items"]]
