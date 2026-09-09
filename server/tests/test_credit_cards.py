from app.models import CreditCardReserveEvent, TransactionChange

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure


def create_credit_card(client, owner_token, budget_id, name="Visa"):
    response = client.post(
        f"/api/v1/budgets/{budget_id}/accounts",
        headers=auth(owner_token),
        json={"name": name, "account_type": "credit", "is_on_budget": True},
    )
    assert response.status_code == 201, response.text
    assert response.json()["payment_category_id"] is not None
    return response.json()


def category_rows(client, owner_token, budget_id):
    summary = client.get(
        f"/api/v1/budgets/{budget_id}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    return summary, {item["name"]: item for item in summary["categories"]}


def account_balance(client, owner_token, budget_id, account_id):
    transactions = client.get(
        f"/api/v1/budgets/{budget_id}/transactions",
        headers=auth(owner_token),
    ).json()
    return sum(item["amount_minor"] for item in transactions if item["account_id"] == account_id)


def test_cash_purchase_reports_cash_overspending_only(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 20000},
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        category_id=groceries["id"],
        amount_minor=-50000,
    )

    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Groceries"]["available_minor"] == -30000
    assert rows["Groceries"]["cash_overspent_minor"] == 30000
    assert rows["Groceries"]["credit_overspent_minor"] == 0
    assert rows["Groceries"]["funded_credit_spending_minor"] == 0


def test_unfunded_card_purchase_reports_credit_debt_only(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    record(
        client,
        owner_token,
        budget["id"],
        account_id=card["id"],
        category_id=groceries["id"],
        amount_minor=-50000,
    )

    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Groceries"]["available_minor"] == -50000
    assert rows["Groceries"]["cash_overspent_minor"] == 0
    assert rows["Groceries"]["credit_overspent_minor"] == 50000
    assert rows["Groceries"]["funded_credit_spending_minor"] == 0


def test_funded_card_purchase_reserves_cash_and_payment_is_not_a_second_expense(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 50000},
    ).status_code == 200

    purchase = record(
        client,
        owner_token,
        budget["id"],
        account_id=card["id"],
        category_id=groceries["id"],
        amount_minor=-30000,
        payee_name="Market",
    )
    assert purchase["amount_minor"] == -30000
    summary, rows = category_rows(client, owner_token, budget["id"])
    assert summary["ready_to_assign_minor"] == 50000
    assert rows["Groceries"]["available_minor"] == 20000
    assert rows["Visa Payment"]["available_minor"] == 30000
    assert rows["Groceries"]["funded_credit_spending_minor"] == 30000
    assert rows["Groceries"]["credit_overspent_minor"] == 0
    assert account_balance(client, owner_token, budget["id"], checking["id"]) == 100000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -30000

    payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": card["id"],
            "amount_minor": 30000,
            "occurred_on": "2026-09-04",
        },
    )
    assert payment.status_code == 201, payment.text
    summary, rows = category_rows(client, owner_token, budget["id"])
    assert summary["ready_to_assign_minor"] == 50000
    assert rows["Groceries"]["activity_minor"] == -30000
    assert rows["Visa Payment"]["available_minor"] == 0
    assert account_balance(client, owner_token, budget["id"], checking["id"]) == 70000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == 0


def test_card_payment_transfer_edit_and_delete_recompute_reserve_atomically(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment", headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 50000})
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000, payee_name="Market")
    payment = client.post(f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token), json={"source_account_id": checking["id"], "destination_account_id": card["id"], "amount_minor": 30000, "occurred_on": "2026-09-04"}).json()
    transfer_id = payment["transfer_id"]
    edited = client.put(f"/api/v1/budgets/{budget['id']}/transfers/{transfer_id}", headers=auth(owner_token), json={"source_account_id": checking["id"], "destination_account_id": card["id"], "amount_minor": 20000, "occurred_on": "2026-09-05", "memo": "partial"})
    assert edited.status_code == 200, edited.text
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Visa Payment"]["available_minor"] == 10000
    assert account_balance(client, owner_token, budget["id"], checking["id"]) == 80000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -10000
    assert client.delete(f"/api/v1/budgets/{budget['id']}/transfers/{transfer_id}", headers=auth(owner_token)).status_code == 204
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Visa Payment"]["available_minor"] == 30000
    assert account_balance(client, owner_token, budget["id"], checking["id"]) == 100000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -30000


def test_partially_funded_purchase_increases_debt_without_inventing_reserve(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 20000},
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=card["id"],
        category_id=groceries["id"],
        amount_minor=-50000,
    )
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Groceries"]["available_minor"] == -30000
    assert rows["Visa Payment"]["available_minor"] == 20000
    assert rows["Groceries"]["credit_overspent_minor"] == 30000
    assert rows["Groceries"]["cash_overspent_minor"] == 0

    unfunded_payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": card["id"],
            "amount_minor": 30000,
            "occurred_on": "2026-09-04",
        },
    )
    assert unfunded_payment.status_code == 409
    funded_payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": card["id"],
            "amount_minor": 20000,
            "occurred_on": "2026-09-04",
        },
    )
    assert funded_payment.status_code == 201
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -30000


def test_card_refund_releases_payment_reserve_and_restores_category(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 50000},
    )
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=10000)

    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Groceries"]["available_minor"] == 30000
    assert rows["Visa Payment"]["available_minor"] == 20000
    assert rows["Groceries"]["funded_credit_spending_minor"] == 20000
    assert rows["Groceries"]["credit_overspent_minor"] == 0
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -20000


def test_existing_card_debt_can_be_funded_without_creating_income(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-100000)
    summary, rows = category_rows(client, owner_token, budget["id"])
    assert summary["ready_to_assign_minor"] == 100000

    assignment = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{card['payment_category_id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 40000},
    )
    assert assignment.status_code == 200
    payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers",
        headers=auth(owner_token),
        json={
            "source_account_id": checking["id"],
            "destination_account_id": card["id"],
            "amount_minor": 40000,
            "occurred_on": "2026-09-04",
        },
    )
    assert payment.status_code == 201
    summary, rows = category_rows(client, owner_token, budget["id"])
    assert summary["ready_to_assign_minor"] == 60000
    assert rows["Visa Payment"]["available_minor"] == 0
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -60000


def test_refund_cannot_release_manual_old_debt_funding_or_another_category_reserve(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{card['payment_category_id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 40000},
    )

    # This purchase is unfunded. Its refund must not release the manual 40,000
    # reserved for existing debt.
    record(
        client, owner_token, budget["id"], account_id=card["id"],
        category_id=groceries["id"], amount_minor=-10000,
    )
    record(
        client, owner_token, budget["id"], account_id=card["id"],
        category_id=groceries["id"], amount_minor=5000,
    )
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Visa Payment"]["available_minor"] == 40000
    assert rows["Groceries"]["available_minor"] == -5000


def test_editing_funded_card_purchase_rebuilds_activity_and_payment_reserve(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    for category_id in (groceries["id"], dining["id"]):
        assert client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{category_id}/assignment",
            headers=auth(owner_token),
            json={"month": "2026-09-01", "assigned_minor": 20000},
        ).status_code == 200

    purchase = record(
        client, owner_token, budget["id"], account_id=card["id"],
        category_id=dining["id"], amount_minor=-10000, payee_name="Bistro",
    )
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Dining"]["activity_minor"] == -10000
    assert rows["Dining"]["available_minor"] == 10000
    assert rows["Visa Payment"]["available_minor"] == 10000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -10000

    edited = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{purchase['id']}",
        headers=auth(owner_token),
        json={
            "account_id": card["id"],
            "category_id": groceries["id"],
            "amount_minor": -12000,
            "occurred_on": "2026-09-04",
            "payee_name": "Bistro",
        },
    )
    assert edited.status_code == 200, edited.text

    _, rows = category_rows(client, owner_token, budget["id"])
    # Original Dining effect fully reversed.
    assert rows["Dining"]["activity_minor"] == 0
    assert rows["Dining"]["available_minor"] == 20000
    # New Groceries effect applied exactly once.
    assert rows["Groceries"]["activity_minor"] == -12000
    assert rows["Groceries"]["available_minor"] == 8000
    # Payment reserve reflects only the edited funded purchase (no duplicate).
    assert rows["Visa Payment"]["available_minor"] == 12000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -12000

    with session_factory() as db:
        reserves = db.query(CreditCardReserveEvent).filter_by(
            source_transaction_id=purchase["id"]
        ).all()
        assert len(reserves) == 1
        assert reserves[0].spending_category_id == groceries["id"]
        assert reserves[0].amount_minor == 12000
        changes = db.query(TransactionChange).filter_by(
            transaction_id=purchase["id"], action="updated"
        ).all()
        assert len(changes) == 1
        assert changes[0].before_json is not None
        assert changes[0].after_json is not None
        assert '"category_id":"' + dining["id"] + '"' in changes[0].before_json
        assert '"category_id":"' + groceries["id"] + '"' in changes[0].after_json


def test_deleting_funded_card_purchase_releases_reserve_and_records_history(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 50000},
    ).status_code == 200

    purchase = record(
        client, owner_token, budget["id"], account_id=card["id"],
        category_id=groceries["id"], amount_minor=-30000, payee_name="Market",
    )
    _, rows = category_rows(client, owner_token, budget["id"])
    assert rows["Groceries"]["available_minor"] == 20000
    assert rows["Visa Payment"]["available_minor"] == 30000
    assert account_balance(client, owner_token, budget["id"], card["id"]) == -30000

    deleted = client.delete(
        f"/api/v1/budgets/{budget['id']}/transactions/{purchase['id']}", headers=auth(owner_token)
    )
    assert deleted.status_code == 204, deleted.text

    _, rows = category_rows(client, owner_token, budget["id"])
    # Category spending fully reversed and the payment reserve released.
    assert rows["Groceries"]["available_minor"] == 50000
    assert rows["Groceries"]["activity_minor"] == 0
    assert rows["Visa Payment"]["available_minor"] == 0
    assert account_balance(client, owner_token, budget["id"], card["id"]) == 0

    with session_factory() as db:
        assert db.query(CreditCardReserveEvent).filter_by(
            source_transaction_id=purchase["id"]
        ).count() == 0
        history = db.query(TransactionChange).filter_by(
            transaction_id=purchase["id"], action="deleted"
        ).all()
        assert len(history) == 1
        assert history[0].before_json is not None
        assert history[0].after_json is None
