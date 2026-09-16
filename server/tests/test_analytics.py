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
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"], amount_minor=-5000, is_cleared=True, occurred_on="2026-09-03", payee_name="Costco")
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=dining["id"], amount_minor=-3000, is_cleared=False, occurred_on="2026-09-05", payee_name="cafe")

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
    # Category-group filter.
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&category_group=Fun")[0] == {dining["id"]}
    # Combined filters intersect (Fun group + cleared true has no rows).
    assert ids(f"{base}?start_date=2026-09-01&end_date=2026-09-30&category_group=Fun&cleared=true")[0] == set()


def test_net_worth_history_is_exact_transfer_neutral_and_account_explainable(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking"},
    ).json()
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
