from app.models import Household, Membership, TransactionChange, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def add_category(client, owner_token, budget_id, group_name, category_name):
    group = client.post(
        f"/api/v1/budgets/{budget_id}/category-groups",
        headers=auth(owner_token),
        json={"name": group_name},
    ).json()
    response = client.post(
        f"/api/v1/budgets/{budget_id}/categories",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": category_name},
    )
    assert response.status_code == 201
    return response.json()


def record(client, token, budget_id, **values):
    body = {
        "occurred_on": "2026-09-04",
        "payee_name": "Test",
        **values,
    }
    response = client.post(
        f"/api/v1/budgets/{budget_id}/transactions",
        headers=auth(token),
        json=body,
    )
    assert response.status_code == 201, response.text
    return response.json()


def add_restricted_member(session_factory, client):
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="reconciler@example.com", display_name="Reconciler", password_hash=hash_password("restricted password long enough"))
        db.add(member); db.flush(); db.add(Membership(household_id=household.id, user_id=member.id, role="child")); db.commit()
        return member.id, create_access_token(member.id, client.app.state.settings)


def test_split_activity_and_income_feed_month_summary(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=100000,
        is_cleared=True,
    )
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 40000},
    )
    split = record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=-15000,
        is_cleared=True,
        splits=[
            {"category_id": groceries["id"], "amount_minor": -10000},
            {"category_id": dining["id"], "amount_minor": -5000},
        ],
    )
    assert [item["amount_minor"] for item in split["splits"]] == [-10000, -5000]

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    )
    assert summary.status_code == 200
    data = summary.json()
    assert data["ready_to_assign_minor"] == 60000
    assert data["total_assigned_minor"] == 40000
    assert data["total_overspent_minor"] == 5000
    by_name = {item["name"]: item for item in data["categories"]}
    assert by_name["Groceries"]["available_minor"] == 30000
    assert by_name["Dining"]["available_minor"] == -5000


def test_transfer_is_balanced_and_does_not_create_income(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings_response = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings"},
    )
    savings = savings_response.json()
    transfer = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": savings["id"],
            "amount_minor": 25000,
            "occurred_on": "2026-09-04",
        },
    )
    assert transfer.status_code == 201
    data = transfer.json()
    assert data["source"]["amount_minor"] == -25000
    assert data["destination"]["amount_minor"] == 25000
    assert data["source"]["transfer_id"] == data["destination"]["transfer_id"]
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    assert summary["ready_to_assign_minor"] == 0


def test_reconciliation_requires_exact_cleared_balance(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=50000,
        is_cleared=True,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        category_id=category["id"],
        amount_minor=-1250,
        is_cleared=True,
    )

    mismatch = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": 48000, "through_date": "2026-09-30"},
    )
    assert mismatch.status_code == 409
    assert mismatch.json()["detail"]["cleared_balance_minor"] == 48750

    matched = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": 48750, "through_date": "2026-09-30"},
    )
    assert matched.status_code == 200
    assert matched.json()["reconciled_transaction_count"] == 2


def test_account_balance_separates_cleared_uncleared_and_working(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=50000,
        is_cleared=True,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        category_id=category["id"],
        amount_minor=-1250,
        is_cleared=False,
    )

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    )
    assert response.status_code == 200
    assert response.json() == {
        "account_id": account["id"],
        "currency_code": "USD",
        "cleared_balance_minor": 50000,
        "uncleared_balance_minor": -1250,
        "working_balance_minor": 48750,
        "reconciled_balance_minor": None,
    }


def test_reconciliation_adjustment_is_an_explicit_auditable_transaction(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    record(
        client,
        owner_token,
        budget["id"],
        account_id=account["id"],
        amount_minor=50000,
        is_cleared=True,
    )

    response = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={
            "statement_balance_minor": 48750,
            "through_date": "2026-09-30",
            "create_adjustment": True,
            "adjustment_reason": "Statement correction",
        },
    )
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["adjustment_amount_minor"] == -1250
    assert result["adjustment_transaction_id"]

    transactions = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
    ).json()
    adjustment = next(
        item for item in transactions
        if item["id"] == result["adjustment_transaction_id"]
    )
    assert adjustment["payee_name"] == "Reconciliation adjustment"
    assert adjustment["memo"] == "Statement correction"
    assert adjustment["amount_minor"] == -1250
    assert adjustment["is_cleared"] is True
    assert adjustment["is_reconciled"] is True
    assert adjustment["created_by_user_id"]

    balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json()
    assert balance["cleared_balance_minor"] == 48750
    assert balance["working_balance_minor"] == 48750
    assert balance["reconciled_balance_minor"] == 48750


def test_positive_cash_reconciliation_becomes_explicit_real_money_then_allocates(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=50000, is_cleared=True)
    result = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": 55000, "through_date": "2026-09-30", "create_adjustment": True, "adjustment_reason": "Cash found", "expected_cleared_balance_minor": 50000},
    )
    assert result.status_code == 200, result.text
    assert result.json()["adjustment_amount_minor"] == 5000
    summary = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()
    assert summary["ready_to_assign_minor"] == 55000
    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 55000, "expected_allocation_version": summary["allocation_version"]},
    )
    assert assigned.status_code == 200, assigned.text
    assert client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["ready_to_assign_minor"] == 0


def test_credit_reconciliation_changes_debt_without_creating_ready_to_assign(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    create_budget_structure(client, owner_token, budget["id"])
    credit = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit", "is_on_budget": True},
    ).json()
    record(client, owner_token, budget["id"], account_id=credit["id"], amount_minor=-10000, is_cleared=True)
    before = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["ready_to_assign_minor"]
    result = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{credit['id']}/reconcile", headers=auth(owner_token),
        json={"statement_balance_minor": -12000, "through_date": "2026-09-30", "create_adjustment": True, "expected_cleared_balance_minor": -10000},
    )
    assert result.status_code == 200, result.text
    assert result.json()["adjustment_amount_minor"] == -2000
    after = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["ready_to_assign_minor"]
    assert after == before


def test_reconciliation_rejects_stale_balance_and_restricted_adjustment(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=50000, is_cleared=True)
    child_id, child_token = add_restricted_member(session_factory, client)
    grant = client.put(f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token), json={"user_id": child_id, "permission": "contribute"})
    assert grant.status_code == 200, grant.text
    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={"capabilities": ["view_budget", "view_accounts", "view_categories", "reconcile_account"], "restrict_accounts": True, "account_ids": [account["id"]], "restrict_categories": True, "category_ids": [category["id"]]},
    )
    assert profile.status_code == 200, profile.text
    forbidden = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile", headers=auth(child_token),
        json={"statement_balance_minor": 51000, "through_date": "2026-09-30", "create_adjustment": True, "expected_cleared_balance_minor": 50000},
    )
    assert forbidden.status_code == 403
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-1000, is_cleared=True)
    stale = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile", headers=auth(owner_token),
        json={"statement_balance_minor": 49000, "through_date": "2026-09-30", "expected_cleared_balance_minor": 50000},
    )
    assert stale.status_code == 409


def test_split_total_must_equal_transaction_total(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    response = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": account["id"],
            "amount_minor": -1000,
            "occurred_on": "2026-09-04",
            "splits": [{"category_id": category["id"], "amount_minor": -999}],
        },
    )
    assert response.status_code == 422


def test_ready_to_assign_excludes_tracking_cash_and_includes_uncategorized_outflow(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    tracking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Investment", "account_type": "tracking", "is_on_budget": False},
    ).json()
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=10000,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=-250,
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=tracking["id"],
        amount_minor=999999,
    )
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    assert summary["ready_to_assign_minor"] == 9750


def test_transaction_edit_recalculates_category_reports_and_account(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    transaction = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=dining["id"], amount_minor=-12000, payee_name="Incorrect Dining",
    )
    changed = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}",
        headers=auth(owner_token),
        json={
            "account_id": account["id"], "category_id": groceries["id"],
            "amount_minor": -12000, "occurred_on": "2026-09-04",
            "payee_name": "Grocery Store", "memo": "Corrected", "is_cleared": True,
        },
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["category_id"] == groceries["id"]
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    by_id = {item["category_id"]: item for item in summary["categories"]}
    assert by_id[groceries["id"]]["activity_minor"] == -12000
    assert by_id[dining["id"]]["activity_minor"] == 0
    balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)
    ).json()
    assert balance["working_balance_minor"] == -12000
    with session_factory() as db:
        change = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="updated").one()
        assert '"category_id":"' + dining["id"] + '"' in change.before_json
        assert '"category_id":"' + groceries["id"] + '"' in change.after_json

    deleted = client.delete(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}", headers=auth(owner_token)
    )
    assert deleted.status_code == 204
    with session_factory() as db:
        history = db.query(TransactionChange).filter_by(transaction_id=transaction["id"]).all()
        assert [item.action for item in history] == ["updated", "deleted"]
        assert history[-1].before_json is not None


def test_reconciled_transaction_cannot_be_edited_or_deleted(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=category["id"], amount_minor=-1000, is_cleared=True,
    )
    reconciled = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": -1000, "through_date": "2026-09-04"},
    )
    assert reconciled.status_code == 200, reconciled.text
    body = {
        "account_id": account["id"], "category_id": category["id"],
        "amount_minor": -900, "occurred_on": "2026-09-04", "payee_name": "Changed",
    }
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}", headers=auth(owner_token), json=body
    ).status_code == 409
    assert client.delete(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}", headers=auth(owner_token)
    ).status_code == 409


def test_transaction_edit_preserves_resent_metadata_and_split_transitions(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000, is_cleared=True)

    original = record(
        client, owner_token, budget["id"], account_id=checking["id"],
        category_id=groceries["id"], amount_minor=-5000, is_cleared=True,
        payee_name="Market", memo="weekly", flag="red",
        tags=["work", "reimburse"], attachment_metadata=[{"name": "receipt.jpg"}],
    )
    assert original["flag"] == "red"
    assert original["tags"] == ["work", "reimburse"]

    # Client re-sends the full object changing only the amount; metadata must survive.
    edited = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}", headers=auth(owner_token),
        json={
            "account_id": checking["id"], "category_id": groceries["id"], "amount_minor": -6500,
            "occurred_on": "2026-09-04", "payee_name": "Market", "memo": "weekly",
            "is_cleared": True, "flag": "red", "tags": ["work", "reimburse"],
            "attachment_metadata": [{"name": "receipt.jpg"}],
        },
    )
    assert edited.status_code == 200, edited.text
    body = edited.json()
    assert body["amount_minor"] == -6500
    assert body["flag"] == "red"
    assert body["tags"] == ["work", "reimburse"]
    assert body["attachment_metadata"] == [{"name": "receipt.jpg"}]
    assert body["is_cleared"] is True
    assert body["memo"] == "weekly"

    # Single -> split.
    to_split = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}", headers=auth(owner_token),
        json={
            "account_id": checking["id"], "category_id": None, "amount_minor": -12000,
            "occurred_on": "2026-09-04", "payee_name": "Market",
            "splits": [
                {"category_id": groceries["id"], "amount_minor": -8000},
                {"category_id": dining["id"], "amount_minor": -4000},
            ],
        },
    )
    assert to_split.status_code == 200, to_split.text
    assert to_split.json()["category_id"] is None
    assert len(to_split.json()["splits"]) == 2

    # Split -> single.
    to_single = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}", headers=auth(owner_token),
        json={
            "account_id": checking["id"], "category_id": dining["id"], "amount_minor": -3000,
            "occurred_on": "2026-09-04", "payee_name": "Market",
        },
    )
    assert to_single.status_code == 200, to_single.text
    assert to_single.json()["category_id"] == dining["id"]
    assert to_single.json()["splits"] == []

    # A split whose parts do not equal the total is rejected (invariant preserved on edit).
    bad = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}", headers=auth(owner_token),
        json={
            "account_id": checking["id"], "category_id": None, "amount_minor": -10000,
            "occurred_on": "2026-09-04", "payee_name": "Market",
            "splits": [
                {"category_id": groceries["id"], "amount_minor": -4000},
                {"category_id": dining["id"], "amount_minor": -4000},
            ],
        },
    )
    assert bad.status_code == 422
