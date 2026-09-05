"""Server-authoritative cash-vs-credit overspending classification.

`month_summary` now splits a category's overspending into:
  * cash_overspent_minor   — spent from cash beyond funding; "needs coverage"
  * credit_overspent_minor — unfunded card spending that "became card debt"

The credit-card reserve engine remains authoritative for actual reserves/debt;
these fields are a derived, explainable presentation of the same month activity.
"""

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card, category_rows

MONTH = "2026-09-01"


def rows_by_id(client, token, budget_id):
    summary = client.get(f"/api/v1/budgets/{budget_id}/months/{MONTH}", headers=auth(token)).json()
    return {r["category_id"]: r for r in summary["categories"]}


def assign(client, token, budget_id, category_id, amount):
    assert client.put(f"/api/v1/budgets/{budget_id}/categories/{category_id}/assignment",
                      headers=auth(token), json={"month": MONTH, "assigned_minor": amount}).status_code == 200


def test_cash_overspend_needs_coverage(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    assign(client, owner_token, budget["id"], groceries["id"], 20000)
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"], amount_minor=-30000)
    row = rows_by_id(client, owner_token, budget["id"])[groceries["id"]]
    assert row["available_minor"] == -10000
    assert row["cash_overspent_minor"] == 10000
    assert row["credit_overspent_minor"] == 0


def test_funded_credit_purchase_is_not_overspending(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    assign(client, owner_token, budget["id"], groceries["id"], 50000)
    card = [a for a in client.get(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token)).json() if a["account_type"] == "credit"][0]
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    rows = rows_by_id(client, owner_token, budget["id"])
    assert rows[groceries["id"]]["available_minor"] == 20000
    assert rows[groceries["id"]]["cash_overspent_minor"] == 0
    assert rows[groceries["id"]]["credit_overspent_minor"] == 0
    # Funded card spending is reserved for the card payment, not overspending.
    assert rows_by_name(client, owner_token, budget["id"])["Visa Payment"]["available_minor"] == 30000


def test_partially_funded_credit_purchase_becomes_card_debt(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    assign(client, owner_token, budget["id"], groceries["id"], 20000)
    card = credit_account(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    rows = rows_by_id(client, owner_token, budget["id"])
    assert rows[groceries["id"]]["available_minor"] == -10000
    # The unfunded 10,000 became card debt (credit), not a cash shortfall.
    assert rows[groceries["id"]]["credit_overspent_minor"] == 10000
    assert rows[groceries["id"]]["cash_overspent_minor"] == 0


def test_fully_unfunded_credit_purchase_is_all_credit_overspend(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    create_credit_card(client, owner_token, budget["id"])
    card = credit_account(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    row = rows_by_id(client, owner_token, budget["id"])[groceries["id"]]
    assert row["available_minor"] == -30000
    assert row["credit_overspent_minor"] == 30000
    assert row["cash_overspent_minor"] == 0


def test_mixed_cash_and_credit_overspend_splits_correctly(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    assign(client, owner_token, budget["id"], groceries["id"], 20000)
    card = credit_account(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=groceries["id"], amount_minor=-15000)
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-20000)
    row = rows_by_id(client, owner_token, budget["id"])[groceries["id"]]
    assert row["available_minor"] == -15000
    # Overspend 15,000: credit spending (20,000) absorbs it first -> all credit debt.
    assert row["credit_overspent_minor"] == 15000
    assert row["cash_overspent_minor"] == 0


def test_refund_clears_credit_overspend(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    assign(client, owner_token, budget["id"], groceries["id"], 20000)
    card = credit_account(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=30000)
    row = rows_by_id(client, owner_token, budget["id"])[groceries["id"]]
    # Refund nets the credit purchase away: no overspend remains.
    assert row["available_minor"] == 20000
    assert row["credit_overspent_minor"] == 0
    assert row["cash_overspent_minor"] == 0


def rows_by_name(client, token, budget_id):
    _, rows = category_rows(client, token, budget_id)
    return rows


def credit_account(client, token, budget_id):
    return [a for a in client.get(f"/api/v1/budgets/{budget_id}/accounts", headers=auth(token)).json() if a["account_type"] == "credit"][0]
