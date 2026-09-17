import pytest

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure


def test_spending_report_is_explainable_and_split_aware(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    direct = record(
        client, owner_token, budget["id"], account_id=checking["id"],
        category_id=dining["id"], amount_minor=-3182, payee_name="Cafe",
    )
    split = record(
        client, owner_token, budget["id"], account_id=checking["id"], amount_minor=-12000,
        splits=[
            {"category_id": dining["id"], "amount_minor": -4000},
            {"category_id": groceries["id"], "amount_minor": -8000},
        ],
    )
    income = record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000)
    report = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/spending?start_date=2026-09-01&end_date=2026-09-30",
        headers=auth(owner_token),
    )
    assert report.status_code == 200, report.text
    by_id = {item["category_id"]: item for item in report.json()["categories"]}
    assert by_id[dining["id"]]["spending_minor"] == 7182
    assert set(by_id[dining["id"]]["transaction_ids"]) == {direct["id"], split["id"]}
    assert by_id[groceries["id"]]["spending_minor"] == 8000
    assert income["id"] not in report.text
    assert report.json()["total_spending_minor"] == 15182


def test_income_spending_excludes_transfers_and_recalculates_after_edit(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings"},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000)
    expense = record(
        client, owner_token, budget["id"], account_id=checking["id"],
        category_id=groceries["id"], amount_minor=-60000,
    )
    transfer = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": savings["id"], "amount_minor": 25000, "occurred_on": "2026-09-04"},
    )
    assert transfer.status_code == 201, transfer.text
    url = f"/api/v1/budgets/{budget['id']}/reports/income-spending?start_date=2026-09-01&end_date=2026-09-30"
    before = client.get(url, headers=auth(owner_token)).json()
    assert before["income_minor"] == 100000
    assert before["spending_minor"] == 60000
    assert before["difference_minor"] == 40000
    assert before["savings_rate"] == 0.4
    assert before["periods"] == [{
        "period_start": "2026-09-01", "period_end": "2026-09-30",
        "income_minor": 100000, "spending_minor": 60000, "difference_minor": 40000,
        "income_transaction_ids": before["income_transaction_ids"],
        "spending_transaction_ids": before["spending_transaction_ids"],
    }]
    changed = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{expense['id']}", headers=auth(owner_token),
        json={"account_id": checking["id"], "category_id": groceries["id"], "amount_minor": -50000, "occurred_on": "2026-09-04"},
    )
    assert changed.status_code == 200, changed.text
    after = client.get(url, headers=auth(owner_token)).json()
    assert after["spending_minor"] == 50000
    assert after["difference_minor"] == 50000


def test_income_spending_monthly_trends_are_exact_split_refund_and_range_aware(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=200000, occurred_on="2026-07-15")
    purchase = record(
        client, owner_token, budget["id"], account_id=checking["id"], amount_minor=-10000,
        occurred_on="2026-07-31", splits=[
            {"category_id": groceries["id"], "amount_minor": -7000},
            {"category_id": dining["id"], "amount_minor": -3000},
        ],
    )
    refund = record(
        client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"],
        amount_minor=2500, occurred_on="2026-08-01",
    )
    september_purchase = record(
        client, owner_token, budget["id"], account_id=checking["id"], category_id=dining["id"],
        amount_minor=-4000, occurred_on="2026-08-31",
    )
    report = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/income-spending?start_date=2026-07-15&end_date=2026-08-31",
        headers=auth(owner_token),
    )
    assert report.status_code == 200, report.text
    body = report.json()
    assert body["income_minor"] == 200000
    assert body["spending_minor"] == 11500
    assert body["difference_minor"] == 188500
    assert body["periods"] == [
        {
            "period_start": "2026-07-15", "period_end": "2026-07-31",
            "income_minor": 200000, "spending_minor": 10000, "difference_minor": 190000,
            "income_transaction_ids": body["income_transaction_ids"],
            "spending_transaction_ids": [purchase["id"]],
        },
        {
            "period_start": "2026-08-01", "period_end": "2026-08-31",
            "income_minor": 0, "spending_minor": 1500, "difference_minor": -1500,
            "income_transaction_ids": [],
            "spending_transaction_ids": [september_purchase["id"], refund["id"]],
        },
    ]


def test_spending_trends_are_ranked_split_refund_transfer_and_payee_aware(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    savings = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings"},
    ).json()
    split = record(
        client, owner_token, budget["id"], account_id=checking["id"], amount_minor=-10000,
        occurred_on="2026-07-31", payee_name="Market", splits=[
            {"category_id": groceries["id"], "amount_minor": -7000},
            {"category_id": dining["id"], "amount_minor": -3000},
        ],
    )
    refund = record(
        client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"],
        amount_minor=2500, occurred_on="2026-08-01", payee_name="Market",
    )
    dining_purchase = record(
        client, owner_token, budget["id"], account_id=checking["id"], category_id=dining["id"],
        amount_minor=-4000, occurred_on="2026-08-31", payee_name="Cafe",
    )
    transfer = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": savings["id"],
              "amount_minor": 2000, "occurred_on": "2026-08-15"},
    )
    assert transfer.status_code == 201
    base = (f"/api/v1/budgets/{budget['id']}/reports/spending-trends"
            "?start_date=2026-07-15&end_date=2026-08-31")

    category = client.get(f"{base}&dimension=category", headers=auth(owner_token))
    assert category.status_code == 200, category.text
    body = category.json()
    assert body["total_spending_minor"] == 11500
    assert [(row["dimension_name"], row["spending_minor"]) for row in body["series"]] == [
        ("Dining", 7000), ("Groceries", 4500),
    ]
    by_name = {row["dimension_name"]: row for row in body["series"]}
    assert [point["spending_minor"] for point in by_name["Groceries"]["points"]] == [7000, -2500]
    assert set(by_name["Groceries"]["transaction_ids"]) == {split["id"], refund["id"]}
    assert transfer.json()["transfer_id"] not in category.text

    group = client.get(f"{base}&dimension=group", headers=auth(owner_token)).json()
    assert [(row["dimension_name"], row["spending_minor"]) for row in group["series"]] == [
        ("Food", 7000), ("Needs", 4500),
    ]
    payee = client.get(f"{base}&dimension=payee", headers=auth(owner_token)).json()
    assert [(row["dimension_name"], row["spending_minor"]) for row in payee["series"]] == [
        ("Market", 7500), ("Cafe", 4000),
    ]
    assert dining_purchase["id"] in payee["series"][1]["transaction_ids"]


def test_spending_trends_limit_and_hidden_scope_are_enforced_before_aggregation(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, hidden_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Delegated", "Allowance")
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=hidden_category["id"],
           amount_minor=-900000, occurred_on="2026-09-01", payee_name="Private Merchant")
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], visible_category["id"])
    own = record(client, child_token, budget["id"], account_id=checking["id"], category_id=visible_category["id"],
                 amount_minor=-2500, occurred_on="2026-09-02", payee_name="Arcade")
    base = (f"/api/v1/budgets/{budget['id']}/reports/spending-trends"
            "?start_date=2026-09-01&end_date=2026-09-30")
    response = client.get(f"{base}&dimension=payee&limit=1", headers=auth(child_token))
    assert response.status_code == 200, response.text
    assert response.json()["total_spending_minor"] == 2500
    assert response.json()["series"][0]["transaction_ids"] == [own["id"]]
    assert "Private Merchant" not in response.text and hidden_category["id"] not in response.text
    assert client.get(f"{base}&category_id={hidden_category['id']}", headers=auth(child_token)).status_code == 404
    assert client.get(f"{base}&limit=26", headers=auth(owner_token)).status_code == 422


def test_income_spending_period_boundaries_handle_leap_day_and_year_rollover(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100,
           occurred_on="2024-02-29")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=200,
           occurred_on="2024-03-01")
    leap = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/income-spending"
        "?start_date=2024-02-29&end_date=2024-03-01", headers=auth(owner_token),
    ).json()
    assert [(row["period_start"], row["period_end"], row["income_minor"]) for row in leap["periods"]] == [
        ("2024-02-29", "2024-02-29", 100), ("2024-03-01", "2024-03-01", 200),
    ]

    year = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/income-spending"
        "?start_date=2023-12-31&end_date=2024-01-01", headers=auth(owner_token),
    ).json()
    assert [(row["period_start"], row["period_end"]) for row in year["periods"]] == [
        ("2023-12-31", "2023-12-31"), ("2024-01-01", "2024-01-01"),
    ]


def test_report_rejects_inverted_period(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/spending?start_date=2026-10-01&end_date=2026-09-01",
        headers=auth(owner_token),
    )
    assert response.status_code == 422


def test_restricted_reports_cannot_leak_hidden_accounts_categories_or_members(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    child_category = add_category(client, owner_token, budget["id"], "Delegated", "Child Fun")
    # Hidden household activity the restricted member must never infer.
    record(
        client, owner_token, budget["id"], account_id=checking["id"],
        amount_minor=900000, is_cleared=True, payee_name="Secret Salary",
    )
    record(
        client, owner_token, budget["id"], account_id=checking["id"],
        category_id=groceries["id"], amount_minor=-45000, payee_name="Private Grocer",
    )
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], child_category["id"])
    # The child's own permitted spending.
    own = record(
        client, child_token, budget["id"], account_id=checking["id"],
        category_id=child_category["id"], amount_minor=-2500, payee_name="Arcade",
    )

    url = f"/api/v1/budgets/{budget['id']}/reports/spending?start_date=2026-09-01&end_date=2026-09-30"
    report = client.get(url, headers=auth(child_token))
    assert report.status_code == 200, report.text
    body = report.json()
    category_ids = {row["category_id"] for row in body["categories"]}
    assert category_ids == {child_category["id"]}
    # Hidden parent category, its payee, and its transaction id must not leak anywhere in the payload.
    assert groceries["id"] not in report.text
    assert "Private Grocer" not in report.text
    assert body["categories"][0]["transaction_ids"] == [own["id"]]
    assert body["total_spending_minor"] == 2500

    income_url = f"/api/v1/budgets/{budget['id']}/reports/income-spending?start_date=2026-09-01&end_date=2026-09-30"
    income = client.get(income_url, headers=auth(child_token))
    assert income.status_code == 200, income.text
    # Parent salary is not visible income to the restricted member.
    assert income.json()["income_minor"] == 0
    assert "Secret Salary" not in income.text

    # Filtering by a hidden category is rejected, not silently broadened.
    forbidden = client.get(
        f"{url}&category_id={groceries['id']}", headers=auth(child_token)
    )
    assert forbidden.status_code == 404


def test_report_filters_and_inclusive_custom_range(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Fun", "Dining")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000, is_cleared=True, occurred_on="2026-09-01", payee_name="Payroll")
    grocery_transaction = record(client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"], amount_minor=-5000, is_cleared=True, occurred_on="2026-09-03", payee_name="Costco", flag="orange", tags=["essential", "qa"])
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=dining["id"], amount_minor=-3000, is_cleared=False, occurred_on="2026-09-05", payee_name="cafe", flag="blue", tags=["fun"])
    from app.models import Transaction
    with session_factory() as db:
        db.get(Transaction, grocery_transaction["id"]).is_reconciled = True
        db.commit()

    base = f"/api/v1/budgets/{budget['id']}/reports/spending"

    def ids(url):
        response = client.get(url, headers=auth(owner_token))
        assert response.status_code == 200, response.text
        return {row["category_id"] for row in response.json()["categories"]}, response.json()["total_spending_minor"]

    # Inclusive single-day custom range.
    single, total = ids(f"{base}?start_date=2026-09-03&end_date=2026-09-03")
    assert single == {groceries["id"]} and total == 5000
    # End date is inclusive: 09-04 excludes the 09-05 dining, 09-05 includes it.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-04")[0] == {groceries["id"]}
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-05")[0] == {groceries["id"], dining["id"]}
    # Payee filter is case-insensitive exact match.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&payee=COSTCO")[0] == {groceries["id"]}
    # Cleared-state filter.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&cleared=false")[0] == {dining["id"]}
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&cleared=true")[0] == {groceries["id"]}
    # Reconciled, flag, and normalized tag filters share the canonical report dataset.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&reconciled=true")[0] == {groceries["id"]}
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&flag=BLUE")[0] == {dining["id"]}
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&tag=ESSENTIAL")[0] == {groceries["id"]}
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&flag=orange&tag=fun")[0] == set()
    # Category-group filter.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&category_group=Fun")[0] == {dining["id"]}
    # Combined filters intersect (Fun group + cleared true has no rows).
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&category_group=Fun&cleared=true")[0] == set()


def test_net_worth_history_is_exact_transfer_neutral_and_account_explainable(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings"},
    ).json()
    loan = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Loan", "account_type": "loan", "is_on_budget": False},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000, occurred_on="2026-07-01")
    record(client, owner_token, budget["id"], account_id=savings["id"], amount_minor=25000, occurred_on="2026-07-01")
    record(client, owner_token, budget["id"], account_id=loan["id"], amount_minor=-50000, occurred_on="2026-07-01")
    transfer = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": savings["id"], "amount_minor": 10000, "occurred_on": "2026-08-15"},
    )
    assert transfer.status_code == 201, transfer.text
    url = f"/api/v1/budgets/{budget['id']}/reports/net-worth?start_date=2026-07-01&end_date=2026-08-31"
    response = client.get(url, headers=auth(owner_token))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["assets_minor"] == 125000
    assert body["liabilities_minor"] == -50000
    assert body["net_worth_minor"] == 75000
    assert [point["net_worth_minor"] for point in body["points"]] == [75000, 75000]
    assert sum(row["balance_minor"] for row in body["accounts"]) == body["net_worth_minor"]
    assert {row["account_id"] for row in body["accounts"]} == {checking["id"], savings["id"], loan["id"]}
    assert all(point["transaction_ids"] == [] for point in body["points"])
    assert all(row["transaction_ids"] == [] for row in body["accounts"])
    explained = client.get(f"{url}&include_transaction_ids=true", headers=auth(owner_token)).json()
    assert explained["points"][-1]["transaction_ids"]
    assert all(row["transaction_ids"] for row in explained["accounts"])
    without_tracking = client.get(f"{url}&include_tracking=false", headers=auth(owner_token)).json()
    assert without_tracking["net_worth_minor"] == 125000
    assert loan["id"] not in str(without_tracking)


def test_net_worth_preserves_ledger_semantics_across_liabilities_payments_and_boundaries(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking"},
    ).json()
    card = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    ).json()

    # Transactions before the requested range are the opening observation balance, while a
    # transaction after the inclusive end boundary must not affect any point or account total.
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000,
           occurred_on="2026-06-30", is_cleared=True)
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-20000,
           occurred_on="2026-06-30", is_cleared=True)
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-5000,
           occurred_on="2026-07-01")
    reserved = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{card['payment_category_id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-07-01", "assigned_minor": 5000},
    )
    assert reserved.status_code == 200, reserved.text
    payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={
            "source_account_id": checking["id"], "destination_account_id": card["id"],
            "amount_minor": 5000, "occurred_on": "2026-07-31",
        },
    )
    assert payment.status_code == 201, payment.text
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=999999,
           occurred_on="2026-08-01")

    report = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/net-worth"
        "?start_date=2026-07-01&end_date=2026-07-31",
        headers=auth(owner_token),
    )
    assert report.status_code == 200, report.text
    body = report.json()
    assert body["points"] == [{
        "as_of": "2026-07-31", "assets_minor": 95000, "liabilities_minor": -20000,
        "net_worth_minor": 75000, "transaction_ids": [],
    }]
    assert body["assets_minor"] == 95000
    assert body["liabilities_minor"] == -20000
    assert body["net_worth_minor"] == 75000
    assert {row["account_name"]: row["balance_minor"] for row in body["accounts"]} == {
        "Card": -20000, "Checking": 95000,
    }


def test_net_worth_counts_reconciliation_adjustments_and_void_reversals_once(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking"},
    ).json()
    opening = record(
        client, owner_token, budget["id"], account_id=checking["id"], amount_minor=10000,
        occurred_on="2026-09-01", is_cleared=True,
    )
    mistaken = record(
        client, owner_token, budget["id"], account_id=checking["id"], amount_minor=-1250,
        occurred_on="2026-09-02", payee_name="Duplicate",
    )
    voided = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions/{mistaken['id']}/void",
        headers=auth(owner_token), json={"reason": "Duplicate"},
    )
    assert voided.status_code == 201, voided.text
    reconciled = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{checking['id']}/reconcile",
        headers=auth(owner_token),
        json={
            "statement_balance_minor": 10500, "through_date": "2026-09-30",
            "create_adjustment": True, "expected_cleared_balance_minor": 10000,
        },
    )
    assert reconciled.status_code == 200, reconciled.text
    assert reconciled.json()["adjustment_amount_minor"] == 500

    report = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/net-worth"
        "?start_date=2026-09-01&end_date=2026-09-30&include_transaction_ids=true",
        headers=auth(owner_token),
    )
    assert report.status_code == 200, report.text
    body = report.json()
    assert body["net_worth_minor"] == 10500
    assert body["assets_minor"] == 10500
    assert body["liabilities_minor"] == 0
    ids = set(body["accounts"][0]["transaction_ids"])
    assert opening["id"] in ids
    assert mistaken["id"] in ids
    assert voided.json()["id"] in ids
    assert reconciled.json()["adjustment_transaction_id"] in ids


def test_debt_history_is_exact_for_loans_cards_and_payments(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking"},
    ).json()
    card = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    ).json()
    loan = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Auto Loan", "account_type": "loan", "is_on_budget": False},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000,
           occurred_on="2026-06-30")
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-20000,
           occurred_on="2026-06-30")
    record(client, owner_token, budget["id"], account_id=loan["id"], amount_minor=-50000,
           occurred_on="2026-06-30")
    payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": loan["id"],
              "amount_minor": 10000, "occurred_on": "2026-07-15"},
    )
    assert payment.status_code == 201, payment.text
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-5000,
           occurred_on="2026-08-01")

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/debt"
        "?start_date=2026-07-01&end_date=2026-08-31", headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["opening_debt_minor"] == 70000
    assert body["debt_minor"] == 65000
    assert body["principal_reduction_minor"] == 5000
    assert [point["debt_minor"] for point in body["points"]] == [60000, 65000]
    assert [(row["account_name"], row["debt_minor"]) for row in body["accounts"]] == [
        ("Auto Loan", 40000), ("Card", 25000),
    ]
    card_only = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/debt"
        f"?start_date=2026-07-01&end_date=2026-08-31&account_id={card['id']}",
        headers=auth(owner_token),
    ).json()
    assert card_only["opening_debt_minor"] == 20000
    assert card_only["debt_minor"] == 25000
    assert card_only["principal_reduction_minor"] == -5000


def test_recorded_interest_is_explicit_split_aware_filterable_and_netted(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    second = add_category(client, owner_token, budget["id"], "Debt", "Interest")
    card = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    ).json()
    loan = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Loan", "account_type": "loan", "is_on_budget": False},
    ).json()
    card_interest = record(
        client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"],
        amount_minor=-10000, occurred_on="2026-09-10", financial_classification="interest_charge",
    )
    loan_interest = record(
        client, owner_token, budget["id"], account_id=loan["id"], amount_minor=-2500,
        occurred_on="2026-08-10", financial_classification="interest_charge",
    )
    split = record(
        client, owner_token, budget["id"], account_id=card["id"], amount_minor=-4000,
        occurred_on="2026-09-12", splits=[
            {"category_id": category["id"], "amount_minor": -3000},
            {"category_id": second["id"], "amount_minor": -1000, "financial_classification": "interest_charge"},
        ],
    )
    record(
        client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"],
        amount_minor=-700, occurred_on="2026-09-13", payee_name="Interest-looking fee",
    )

    url = f"/api/v1/budgets/{budget['id']}/reports/debt?start_date=2026-08-01&end_date=2026-09-30"
    body = client.get(url, headers=auth(owner_token)).json()
    assert body["recorded_interest_range_minor"] == 13500
    assert body["recorded_interest_month_minor"] == 11000
    assert body["recorded_interest_ytd_minor"] == 13500
    assert body["interest_tracking_started_on"] == "2026-08-10"
    assert {row["account_name"]: row["recorded_interest_minor"] for row in body["accounts"]} == {
        "Card": 11000, "Loan": 2500,
    }

    found = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions/search?transaction_type=interest_charge",
        headers=auth(owner_token),
    )
    assert found.status_code == 200, found.text
    assert {item["id"] for item in found.json()["items"]} == {card_interest["id"], loan_interest["id"], split["id"]}

    voided = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions/{card_interest['id']}/void",
        headers=auth(owner_token), json={"reason": "Issuer correction"},
    )
    assert voided.status_code == 201, voided.text
    after_void = client.get(url, headers=auth(owner_token)).json()
    assert after_void["recorded_interest_range_minor"] == 3500
    assert after_void["recorded_interest_month_minor"] == 1000

    loan_only = client.get(url + f"&account_id={loan['id']}", headers=auth(owner_token)).json()
    assert loan_only["recorded_interest_range_minor"] == 2500


def test_recorded_interest_respects_category_scope_on_visible_debt_account(client, owner_token, session_factory):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    _, hidden_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Shared", "Visible interest")
    card_response = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Shared card", "account_type": "credit"},
    )
    assert card_response.status_code == 201
    card = card_response.json()
    for category_id, amount, day in [
        (hidden_category["id"], -9000, "2026-09-01"),
        (visible_category["id"], -1000, "2026-09-10"),
    ]:
        record(client, owner_token, budget["id"], account_id=card["id"], category_id=category_id,
               amount_minor=amount, occurred_on=day, financial_classification="interest_charge")
    # A partially hidden split is not a visible transaction in the canonical browser contract.
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-3000,
           occurred_on="2026-09-02", splits=[
               {"category_id": visible_category["id"], "amount_minor": -1000, "financial_classification": "interest_charge"},
               {"category_id": hidden_category["id"], "amount_minor": -2000, "financial_classification": "interest_charge"},
           ])
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, card["id"], visible_category["id"])
    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={"capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
              "restrict_accounts": True, "account_ids": [card["id"]],
              "restrict_categories": True, "category_ids": [visible_category["id"]]},
    )
    assert profile.status_code == 200, profile.text
    url = f"/api/v1/budgets/{budget['id']}/reports/debt?start_date=2026-09-01&end_date=2026-09-30"
    owner = client.get(url, headers=auth(owner_token))
    assert owner.status_code == 200
    assert owner.json()["recorded_interest_range_minor"] == 13000
    restricted = client.get(url, headers=auth(child_token))
    assert restricted.status_code == 200, restricted.text
    body = restricted.json()
    for field in ("recorded_interest_range_minor", "recorded_interest_month_minor", "recorded_interest_ytd_minor", "recorded_interest_trailing_12_minor"):
        assert body[field] == 1000, field
    assert body["accounts"][0]["recorded_interest_minor"] == 1000
    assert body["interest_tracking_started_on"] == "2026-09-10"
    # Balance access is independently authorized: filtering interest must not redefine card debt.
    assert body["debt_minor"] == owner.json()["debt_minor"] == 13000


def test_interest_classification_requires_debt_account(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    response = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
        json={"account_id": checking["id"], "category_id": category["id"], "amount_minor": -10000,
              "occurred_on": "2026-09-10", "financial_classification": "interest_charge"},
    )
    assert response.status_code == 422


def test_debt_report_filters_hidden_accounts_before_aggregation(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    hidden = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Private Mortgage", "account_type": "loan", "is_on_budget": False},
    ).json()
    record(client, owner_token, budget["id"], account_id=hidden["id"], amount_minor=-25000000,
           occurred_on="2026-01-01", financial_classification="interest_charge")
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], category["id"])
    expanded = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={
            "capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
            "restrict_accounts": True, "account_ids": [checking["id"]],
            "restrict_categories": True, "category_ids": [category["id"]],
        },
    )
    assert expanded.status_code == 200, expanded.text
    url = f"/api/v1/budgets/{budget['id']}/reports/debt?start_date=2026-01-01&end_date=2026-09-30"
    visible = client.get(url, headers=auth(child_token))
    assert visible.status_code == 200
    assert visible.json()["debt_minor"] == 0
    assert visible.json()["recorded_interest_range_minor"] == 0
    assert visible.json()["interest_tracking_started_on"] is None
    assert hidden["id"] not in visible.text and "Private Mortgage" not in visible.text
    assert client.get(f"{url}&account_id={hidden['id']}", headers=auth(child_token)).status_code == 404


def test_debt_history_reconciles_payments_reconciliation_voids_and_net_worth(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    card = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000,
           occurred_on="2026-06-30", is_cleared=True)
    record(client, owner_token, budget["id"], account_id=card["id"], amount_minor=-20000,
           occurred_on="2026-06-30", is_cleared=True)
    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-07-01", "assigned_minor": 5000},
    )
    assert assigned.status_code == 200, assigned.text
    purchase = record(
        client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-5000,
        occurred_on="2026-07-01", is_cleared=True,
    )
    payment = client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": card["id"],
              "amount_minor": 3000, "occurred_on": "2026-07-15", "is_cleared": True},
    )
    assert payment.status_code == 201, payment.text
    mistaken = record(
        client, owner_token, budget["id"], account_id=card["id"], amount_minor=-2000,
        occurred_on="2026-07-20", is_cleared=True,
    )
    voided = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions/{mistaken['id']}/void",
        headers=auth(owner_token), json={"reason": "Duplicate"},
    )
    assert voided.status_code == 201, voided.text
    reconciled = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{card['id']}/reconcile",
        headers=auth(owner_token),
        json={"statement_balance_minor": -21500, "through_date": "2026-07-31",
              "create_adjustment": True, "expected_cleared_balance_minor": -24000},
    )
    assert reconciled.status_code == 200, reconciled.text
    assert reconciled.json()["adjustment_amount_minor"] == 2500

    debt = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/debt"
        "?start_date=2026-07-01&end_date=2026-07-31", headers=auth(owner_token),
    )
    net_worth = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/net-worth"
        "?start_date=2026-07-01&end_date=2026-07-31", headers=auth(owner_token),
    )
    assert debt.status_code == 200 and net_worth.status_code == 200
    debt_body, worth_body = debt.json(), net_worth.json()
    assert debt_body["opening_debt_minor"] == 20000
    assert debt_body["debt_minor"] == 21500
    assert debt_body["principal_reduction_minor"] == -1500
    assert sum(row["debt_minor"] for row in debt_body["accounts"]) == debt_body["debt_minor"]
    assert worth_body["assets_minor"] == 97000
    assert worth_body["liabilities_minor"] == -21500
    assert worth_body["net_worth_minor"] == 75500
    assert worth_body["assets_minor"] + worth_body["liabilities_minor"] == worth_body["net_worth_minor"]
    # The card payment changes account contributions but not household net worth. The void and
    # reversal net exactly, while the reconciliation adjustment is observed once.
    assert purchase["id"] != mistaken["id"]


@pytest.mark.parametrize("month_count", [12, 60, 132])
def test_debt_long_history_is_monthly_exact_and_response_bounded(
    client, owner_token, session_factory, month_count
):
    from datetime import date
    import json
    from sqlalchemy import event, select
    from app.models import Transaction, User

    budget = create_budget(client, owner_token, session_factory)
    loan = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Long-lived Loan", "account_type": "loan", "is_on_budget": False},
    ).json()
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        rows = []
        for month_index in range(month_count):
            year = 2016 + month_index // 12
            month = month_index % 12 + 1
            rows.extend(Transaction(
                budget_id=budget["id"], account_id=loan["id"], amount_minor=-100,
                occurred_on=date(year, month, day), created_by_user_id=owner_id,
            ) for day in range(1, 11))
        db.add_all(rows)
        db.commit()

    end_year = 2016 + (month_count - 1) // 12
    end_month = (month_count - 1) % 12 + 1
    statements = []
    engine = session_factory.kw["bind"]
    def capture(_connection, _cursor, statement, _parameters, _context, _executemany):
        statements.append(statement)
    event.listen(engine, "before_cursor_execute", capture)
    try:
        response = client.get(
            f"/api/v1/budgets/{budget['id']}/reports/debt"
            f"?start_date=2016-01-01&end_date={end_year:04d}-{end_month:02d}-28",
            headers=auth(owner_token),
        )
    finally:
        event.remove(engine, "before_cursor_execute", capture)
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["points"]) == month_count
    assert body["debt_minor"] == month_count * 1000
    assert body["accounts"] == [{
        "account_id": loan["id"], "account_name": "Long-lived Loan", "account_type": "loan",
        "is_on_budget": False, "debt_minor": month_count * 1000, "recorded_interest_minor": 0,
    }]
    assert len(json.dumps(body)) < 25_000
    # Query work is constant with history length: authorization/scope, accounts, then one ordered
    # ledger read. Guard generously against incidental auth-query evolution while preventing N+1.
    assert len(statements) <= 15


def test_plan_performance_history_reconciles_assignments_activity_rollover_and_card_reserve(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    card = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000,
           occurred_on="2026-06-30")
    for category, amount in ((groceries, 30000), (dining, 10000)):
        assigned = client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
            headers=auth(owner_token), json={"month": "2026-07-01", "assigned_minor": amount},
        )
        assert assigned.status_code == 200, assigned.text
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=-12000,
           occurred_on="2026-07-15", splits=[
               {"category_id": groceries["id"], "amount_minor": -8000},
               {"category_id": dining["id"], "amount_minor": -4000},
           ])
    moved = client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(owner_token),
        json={"source_category_id": groceries["id"], "destination_category_id": dining["id"],
              "amount_minor": 5000, "occurred_on": "2026-08-01", "expected_allocation_version": 2},
    )
    assert moved.status_code == 201, moved.text
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=dining["id"],
           amount_minor=-4000, occurred_on="2026-08-02")
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"],
           amount_minor=2000, occurred_on="2026-08-03")

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/plan-performance"
        "?start_date=2026-07-01&end_date=2026-08-31", headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    july, august = response.json()["points"]
    assert july == {
        "period_start": "2026-07-01", "period_end": "2026-07-31",
        "assigned_minor": 40000, "activity_minor": -12000, "spending_minor": 12000,
        "carried_available_minor": 0, "available_minor": 28000,
        "overspent_minor": 0, "ready_to_assign_minor": 60000,
    }
    assert august["assigned_minor"] == 0  # Move Money nets to zero; it is not new funding.
    assert august["carried_available_minor"] == 28000
    assert august["activity_minor"] == 2000  # -4,000 spending + 4,000 reserve + 2,000 refund.
    assert august["spending_minor"] == 2000  # Purchase less refund; reserve is not double-counted.
    assert august["available_minor"] == 30000
    assert august["ready_to_assign_minor"] == 60000
    current = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-08-01", headers=auth(owner_token),
    ).json()
    assert current["ready_to_assign_minor"] == august["ready_to_assign_minor"]
    assert current["total_assigned_minor"] == august["assigned_minor"]
    assert sum(row["activity_minor"] for row in current["categories"]) == august["activity_minor"]
    assert sum(row["available_minor"] for row in current["categories"]) == august["available_minor"]


def test_plan_performance_restricted_scope_cannot_leak_hidden_plan_values(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, hidden = create_budget_structure(client, owner_token, budget["id"])
    visible = add_category(client, owner_token, budget["id"], "Delegated", "Allowance")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=500000,
           occurred_on="2026-08-31")
    client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{hidden['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 100000},
    )
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], visible["id"])
    expanded = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={"capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
              "restrict_accounts": True, "account_ids": [checking["id"]],
              "restrict_categories": True, "category_ids": [visible["id"]]},
    )
    assert expanded.status_code == 200
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/plan-performance"
        "?start_date=2026-09-01&end_date=2026-09-30", headers=auth(child_token),
    )
    assert response.status_code == 200, response.text
    point = response.json()["points"][0]
    assert point["ready_to_assign_minor"] == 0
    assert point["assigned_minor"] == 0
    assert point["available_minor"] == 0
    assert hidden["id"] not in response.text and "100000" not in response.text


@pytest.mark.parametrize("month_count", [12, 60, 132])
def test_plan_performance_long_history_is_monthly_bounded_and_constant_query_count(
    client, owner_token, session_factory, month_count
):
    from datetime import date
    import json
    from sqlalchemy import event, select
    from app.models import Transaction, User

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        rows = []
        for month_index in range(month_count):
            year = 2016 + month_index // 12
            month = month_index % 12 + 1
            rows.extend(Transaction(
                budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
                amount_minor=-100, occurred_on=date(year, month, day), created_by_user_id=owner_id,
            ) for day in range(1, 11))
        db.add_all(rows)
        db.commit()
    end_year = 2016 + (month_count - 1) // 12
    end_month = (month_count - 1) % 12 + 1
    statements = []
    engine = session_factory.kw["bind"]
    def capture(_connection, _cursor, statement, _parameters, _context, _executemany):
        statements.append(statement)
    event.listen(engine, "before_cursor_execute", capture)
    try:
        response = client.get(
            f"/api/v1/budgets/{budget['id']}/reports/plan-performance"
            f"?start_date=2016-01-01&end_date={end_year:04d}-{end_month:02d}-28",
            headers=auth(owner_token),
        )
    finally:
        event.remove(engine, "before_cursor_execute", capture)
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["points"]) == month_count
    assert all(point["spending_minor"] == 1000 for point in body["points"])
    assert body["points"][-1]["available_minor"] == -(month_count * 1000)
    assert len(json.dumps(body)) < 50_000
    assert len(statements) <= 20


def test_resilience_report_uses_visible_cash_and_forecast_without_invented_coverage(
    client, owner_token, session_factory, monkeypatch
):
    from datetime import date
    from app import analytics_routes, planning_routes
    from .conftest import freeze_today

    today = date(2026, 9, 1)
    freeze_today(monkeypatch, today, planning_routes)
    freeze_today(monkeypatch, today, analytics_routes)
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=100000,
           occurred_on="2026-09-01")
    for name, amount, next_date in (("Paycheck", 50000, "2026-09-10"), ("Rent", -30000, "2026-09-15")):
        response = client.post(
            f"/api/v1/budgets/{budget['id']}/scheduled-transactions", headers=auth(owner_token),
            json={"account_id": checking["id"], "category_id": category["id"] if amount < 0 else None,
                  "name": name, "amount_minor": amount, "next_date": next_date,
                  "recurrence_unit": "once", "interval_count": 1},
        )
        assert response.status_code == 201, response.text
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/resilience?horizon_days=30",
        headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["cash_buffer_minor"] == 100000
    assert body["current_on_budget_minor"] == 100000
    assert body["projected_on_budget_minor"] == 120000
    assert body["lowest_projected_on_budget_minor"] == 100000
    assert body["scheduled_income_minor"] == 50000
    assert body["scheduled_outflows_minor"] == 30000
    assert body["expected_margin_minor"] == 20000
    assert body["essential_expense_coverage_days"] is None
    assert body["emergency_fund_coverage_days"] is None
    assert set(body["unavailable_metrics"]) == {
        "essential_expense_coverage_days", "emergency_fund_coverage_days",
    }
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/reports/resilience?horizon_days=91",
        headers=auth(owner_token),
    ).status_code == 422


def test_resilience_report_filters_hidden_accounts_and_schedules_before_aggregation(
    client, owner_token, session_factory, monkeypatch
):
    from datetime import date
    from app import analytics_routes, planning_routes
    from .conftest import freeze_today
    from .test_delegated_access import add_child, configure_child

    today = date(2026, 9, 1)
    freeze_today(monkeypatch, today, planning_routes); freeze_today(monkeypatch, today, analytics_routes)
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    hidden = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Private Savings", "account_type": "savings"},
    ).json()
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=10000,
           occurred_on="2026-09-01")
    record(client, owner_token, budget["id"], account_id=hidden["id"], amount_minor=900000,
           occurred_on="2026-09-01")
    scheduled = client.post(
        f"/api/v1/budgets/{budget['id']}/scheduled-transactions", headers=auth(owner_token),
        json={"account_id": hidden["id"], "name": "Private bonus", "amount_minor": 500000,
              "next_date": "2026-09-10", "recurrence_unit": "once", "interval_count": 1},
    )
    assert scheduled.status_code == 201
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], category["id"])
    expanded = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={"capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
              "restrict_accounts": True, "account_ids": [checking["id"]],
              "restrict_categories": True, "category_ids": [category["id"]]},
    )
    assert expanded.status_code == 200
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/resilience", headers=auth(child_token),
    )
    assert response.status_code == 200, response.text
    assert response.json()["cash_buffer_minor"] == 10000
    assert response.json()["scheduled_income_minor"] == 0
    assert hidden["id"] not in response.text and "Private bonus" not in response.text


def test_report_csv_export_is_open_bounded_and_spreadsheet_safe(
    client, owner_token, session_factory
):
    import csv
    import io

    budget = create_budget(client, owner_token, session_factory)
    checking, _category = create_budget_structure(client, owner_token, budget["id"])
    formula_category = add_category(client, owner_token, budget["id"], "Audit", "=IMPORTDATA(secret)")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=10000,
           occurred_on="2026-09-01")
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=formula_category["id"],
           amount_minor=-2500, occurred_on="2026-09-02")
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/export.csv"
        "?start_date=2026-09-01&end_date=2026-09-30", headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("text/csv")
    assert "budget-reports-2026-09-01-2026-09-30.csv" in response.headers["content-disposition"]
    rows = list(csv.DictReader(io.StringIO(response.text)))
    assert {row["report"] for row in rows} >= {"spending", "cash_flow", "net_worth", "debt", "plan"}
    spending = next(row for row in rows if row["report"] == "spending")
    assert spending["name"] == "'=IMPORTDATA(secret)"
    assert spending["amount_minor"] == "2500"
    assert all(set(row) == {"report", "period_start", "period_end", "dimension", "name", "amount_minor", "currency_code"} for row in rows)


def test_report_csv_export_requires_export_capability(client, owner_token, session_factory):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], category["id"])
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/export.csv"
        "?start_date=2026-09-01&end_date=2026-09-30", headers=auth(child_token),
    )
    assert response.status_code == 403


def test_net_worth_rejects_hidden_account_filter_and_never_aggregates_it(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    hidden = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Private", "account_type": "tracking", "is_on_budget": False, "starting_balance_minor": 900000},
    ).json()
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], groceries["id"])
    expanded = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={
            "capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports"],
            "restrict_accounts": True, "account_ids": [checking["id"]],
            "restrict_categories": True, "category_ids": [groceries["id"]],
        },
    )
    assert expanded.status_code == 200, expanded.text
    url = f"/api/v1/budgets/{budget['id']}/reports/net-worth?start_date=2026-09-01&end_date=2026-09-30"
    response = client.get(url, headers=auth(child_token))
    assert response.status_code == 200, response.text
    assert hidden["id"] not in response.text
    assert response.json()["net_worth_minor"] == 0
    forbidden = client.get(f"{url}&account_id={hidden['id']}", headers=auth(child_token))
    assert forbidden.status_code == 404


def test_reports_reject_cross_budget_resource_filters(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    create_budget_structure(client, owner_token, budget["id"])
    other = create_budget(client, owner_token, session_factory)
    other_account, other_category = create_budget_structure(client, owner_token, other["id"])
    base = f"/api/v1/budgets/{budget['id']}/reports"
    period = "start_date=2026-09-01&end_date=2026-09-30"

    for path in (
        f"spending?{period}&account_id={other_account['id']}",
        f"spending?{period}&category_id={other_category['id']}",
        f"spending-trends?{period}&account_id={other_account['id']}",
        f"spending-trends?{period}&category_id={other_category['id']}",
        f"income-spending?{period}&account_id={other_account['id']}",
        f"net-worth?{period}&account_id={other_account['id']}",
    ):
        response = client.get(f"{base}/{path}", headers=auth(owner_token))
        assert response.status_code == 404, (path, response.text)


def test_restricted_report_member_and_group_filters_do_not_disclose_hidden_scope(
    client, owner_token, session_factory
):
    from .test_delegated_access import add_child, configure_child

    budget = create_budget(client, owner_token, session_factory)
    checking, hidden_category = create_budget_structure(client, owner_token, budget["id"])
    visible_category = add_category(client, owner_token, budget["id"], "Delegated", "Allowance")
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], visible_category["id"])
    base = f"/api/v1/budgets/{budget['id']}/reports/spending?start_date=2026-09-01&end_date=2026-09-30"

    # A restricted member can filter their own activity, but cannot probe another actor or a
    # group that contains only hidden categories. Both hidden and nonexistent probes are identical.
    assert client.get(f"{base}&member_id={child_id}", headers=auth(child_token)).status_code == 200
    from app.models import User
    from sqlalchemy import select
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
    hidden_member = client.get(f"{base}&member_id={owner_id}", headers=auth(child_token))
    hidden_group = client.get(f"{base}&category_group=Everyday", headers=auth(child_token))
    assert hidden_member.status_code == 404
    assert hidden_group.status_code == 404
    assert hidden_category["id"] not in hidden_group.text


@pytest.mark.parametrize("month_count", [12, 60, 132])
def test_net_worth_long_history_is_monthly_and_default_payload_is_bounded(
    client, owner_token, session_factory, month_count
):
    from datetime import date
    import json
    from sqlalchemy import select
    from app.models import Transaction, User

    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        rows = []
        # Ten transactions per month over eleven years: enough to catch accidental client hydration
        # or a response that repeats the complete ledger at every monthly observation.
        for month_index in range(month_count):
            year = 2016 + month_index // 12
            month = month_index % 12 + 1
            for day in range(1, 11):
                rows.append(Transaction(
                    budget_id=budget["id"], account_id=account["id"], amount_minor=100,
                    occurred_on=date(year, month, day), created_by_user_id=owner_id,
                ))
        db.add_all(rows)
        db.commit()

    end_year = 2016 + (month_count - 1) // 12
    end_month = (month_count - 1) % 12 + 1
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/net-worth?start_date=2016-01-01&end_date={end_year:04d}-{end_month:02d}-28",
        headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["points"]) == month_count
    assert body["net_worth_minor"] == month_count * 1000
    assert all(point["transaction_ids"] == [] for point in body["points"])
    assert len(json.dumps(body)) < 100_000


def test_report_provenance_is_bounded_without_changing_exact_totals(
    client, owner_token, session_factory
):
    from datetime import date
    from sqlalchemy import select
    from app.models import Transaction, User

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        db.add_all([
            Transaction(
                budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
                amount_minor=-100, occurred_on=date(2026, 9, 15), created_by_user_id=owner_id,
            )
            for _ in range(501)
        ])
        db.commit()

    base = f"/api/v1/budgets/{budget['id']}/reports"
    dates = "?start_date=2026-09-01&end_date=2026-09-30"
    spending = client.get(f"{base}/spending{dates}", headers=auth(owner_token)).json()
    category_row = spending["categories"][0]
    assert spending["total_spending_minor"] == 50_100
    assert len(category_row["transaction_ids"]) == 500
    assert category_row["transaction_ids_truncated"] is True

    cash_flow = client.get(f"{base}/income-spending{dates}", headers=auth(owner_token)).json()
    assert cash_flow["spending_minor"] == 50_100
    assert len(cash_flow["spending_transaction_ids"]) == 500
    assert cash_flow["spending_transaction_ids_truncated"] is True
    assert len(cash_flow["periods"][0]["spending_transaction_ids"]) == 500
    assert cash_flow["periods"][0]["spending_transaction_ids_truncated"] is True

    trends = client.get(f"{base}/spending-trends{dates}", headers=auth(owner_token)).json()
    assert trends["series"][0]["spending_minor"] == 50_100
    assert len(trends["series"][0]["transaction_ids"]) == 500
    assert trends["series"][0]["transaction_ids_truncated"] is True
    assert trends["series"][0]["points"][0]["transaction_ids_truncated"] is True

    worth = client.get(f"{base}/net-worth{dates}&include_transaction_ids=true", headers=auth(owner_token)).json()
    assert worth["net_worth_minor"] == -50_100
    assert len(worth["points"][0]["transaction_ids"]) == 500
    assert worth["points"][0]["transaction_ids_truncated"] is True


@pytest.mark.parametrize("month_count", [12, 60, 132])
def test_spending_cash_flow_trends_and_export_scale_remain_bounded(
    client, owner_token, session_factory, month_count
):
    from datetime import date
    import json
    from sqlalchemy import event, select
    from app.models import Transaction, User

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        rows = []
        for month_index in range(month_count):
            year = 2016 + month_index // 12
            month = month_index % 12 + 1
            rows.extend(Transaction(
                budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
                amount_minor=-100, occurred_on=date(year, month, day), created_by_user_id=owner_id,
            ) for day in range(1, 11))
        db.add_all(rows)
        db.commit()
    end_year = 2016 + (month_count - 1) // 12
    end_month = (month_count - 1) % 12 + 1
    base = f"/api/v1/budgets/{budget['id']}/reports"
    dates = f"?start_date=2016-01-01&end_date={end_year:04d}-{end_month:02d}-28"
    statements = []
    engine = session_factory.kw["bind"]
    def capture(_connection, _cursor, statement, _parameters, _context, _executemany):
        statements.append(statement)
    event.listen(engine, "before_cursor_execute", capture)
    try:
        spending = client.get(f"{base}/spending{dates}", headers=auth(owner_token))
        cash_flow = client.get(f"{base}/income-spending{dates}", headers=auth(owner_token))
        trends = client.get(f"{base}/spending-trends{dates}", headers=auth(owner_token))
        export = client.get(f"{base}/export.csv{dates}", headers=auth(owner_token))
    finally:
        event.remove(engine, "before_cursor_execute", capture)
    assert all(response.status_code == 200 for response in (spending, cash_flow, trends, export))
    expected = month_count * 1000
    assert spending.json()["total_spending_minor"] == expected
    assert cash_flow.json()["spending_minor"] == expected
    assert trends.json()["total_spending_minor"] == expected
    assert len(cash_flow.json()["periods"]) == month_count
    assert len(trends.json()["series"][0]["points"]) == month_count
    assert len(json.dumps(spending.json())) < 25_000
    assert len(json.dumps(cash_flow.json())) < 100_000
    assert len(json.dumps(trends.json())) < 100_000
    assert len(export.content) < 100_000
    # Four complete requests remain bounded. SQLAlchemy's split select-in loader intentionally adds
    # one statement per 500 parent rows; the guard catches per-month/per-transaction N+1 behavior.
    assert len(statements) <= 120


@pytest.mark.parametrize("path", [
    "spending?start_date=2026-09-01&end_date=2026-09-30",
    "income-spending?start_date=2026-09-01&end_date=2026-09-30",
    "spending-trends?start_date=2026-09-01&end_date=2026-09-30",
    "net-worth?start_date=2026-09-01&end_date=2026-09-30",
    "debt?start_date=2026-09-01&end_date=2026-09-30",
    "plan-performance?start_date=2026-09-01&end_date=2026-09-30",
    "resilience?horizon_days=30",
    "export.csv?start_date=2026-09-01&end_date=2026-09-30",
])
def test_every_report_rejects_missing_auth_and_unknown_budget(client, owner_token, path):
    url = f"/api/v1/budgets/00000000-0000-0000-0000-000000000000/reports/{path}"
    assert client.get(url).status_code == 401
    assert client.get(url, headers=auth(owner_token)).status_code in (403, 404)


@pytest.mark.parametrize("report", [
    "spending", "income-spending", "spending-trends", "net-worth", "debt",
    "plan-performance", "export.csv",
])
def test_historical_reports_reject_more_than_fifty_years(
    client, owner_token, session_factory, report
):
    budget = create_budget(client, owner_token, session_factory)
    response = client.get(
        f"/api/v1/budgets/{budget['id']}/reports/{report}"
        "?start_date=1976-01-01&end_date=2026-01-31",
        headers=auth(owner_token),
    )
    assert response.status_code == 422
    assert "600 calendar months" in response.text


def test_every_report_has_a_stable_empty_budget_response(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    base = f"/api/v1/budgets/{budget['id']}/reports"
    dates = "?start_date=2026-09-01&end_date=2026-09-30"
    spending = client.get(f"{base}/spending{dates}", headers=auth(owner_token))
    income = client.get(f"{base}/income-spending{dates}", headers=auth(owner_token))
    trends = client.get(f"{base}/spending-trends{dates}", headers=auth(owner_token))
    worth = client.get(f"{base}/net-worth{dates}", headers=auth(owner_token))
    debt = client.get(f"{base}/debt{dates}", headers=auth(owner_token))
    plan = client.get(f"{base}/plan-performance{dates}", headers=auth(owner_token))
    resilience = client.get(f"{base}/resilience?horizon_days=30", headers=auth(owner_token))
    export = client.get(f"{base}/export.csv{dates}", headers=auth(owner_token))
    assert all(response.status_code == 200 for response in (spending, income, trends, worth, debt, plan, resilience, export))
    assert spending.json()["categories"] == []
    assert trends.json()["series"] == []
    assert income.json()["income_minor"] == income.json()["spending_minor"] == 0
    assert worth.json()["accounts"] == [] and worth.json()["net_worth_minor"] == 0
    assert debt.json()["accounts"] == [] and debt.json()["debt_minor"] == 0
    assert plan.json()["points"][0]["available_minor"] == 0
    assert resilience.json()["cash_buffer_minor"] == 0
    assert export.text.startswith("report,period_start,period_end,dimension,name,amount_minor,currency_code\n")
