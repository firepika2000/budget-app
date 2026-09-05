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
    changed = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{expense['id']}", headers=auth(owner_token),
        json={"account_id": checking["id"], "category_id": groceries["id"], "amount_minor": -50000, "occurred_on": "2026-09-04"},
    )
    assert changed.status_code == 200, changed.text
    after = client.get(url, headers=auth(owner_token)).json()
    assert after["spending_minor"] == 50000
    assert after["difference_minor"] == 50000


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
