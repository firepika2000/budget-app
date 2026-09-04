from .conftest import auth
from .test_advanced_ledger import record
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
