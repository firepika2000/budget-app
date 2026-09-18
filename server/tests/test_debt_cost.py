from datetime import date, timedelta

import pytest

from app.debt_projection import MAX_MONEY, estimated_monthly_interest
from .conftest import auth
from .test_budgeting_api import create_budget
from .test_debt_projection import create_strategy_card
from .test_delegated_access import add_child


def test_monthly_cost_is_exact_and_bounded():
    assert estimated_monthly_interest(100_000, 1300) == 1083
    assert estimated_monthly_interest(50, 1200) == 1
    assert estimated_monthly_interest(MAX_MONEY, 0) == 0
    assert estimated_monthly_interest(MAX_MONEY, 100_000) == (MAX_MONEY * 100_000 + 60_000) // 120_000
    with pytest.raises(ValueError):
        estimated_monthly_interest(MAX_MONEY + 1, 0)
    with pytest.raises(ValueError):
        estimated_monthly_interest(100, -1)


def test_current_cost_keeps_missing_rates_unknown_and_preserves_posted_money(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    base = f"/api/v1/budgets/{budget['id']}"
    card = create_strategy_card(client, owner_token, budget["id"], "Card", 10_000, 1200, 500)
    unknown = client.post(f"{base}/accounts", headers=auth(owner_token), json={
        "name": "Unknown loan", "account_type": "loan", "is_on_budget": False, "starting_balance_minor": -20_000,
    })
    assert unknown.status_code == 201, unknown.text
    cash = client.post(f"{base}/accounts", headers=auth(owner_token), json={"name": "Cash", "account_type": "checking"})
    assert cash.status_code == 201, cash.text
    cash_cost = client.get(f"{base}/reports/debt-cost?account_id={cash.json()['id']}", headers=auth(owner_token))
    assert cash_cost.status_code == 200
    assert cash_cost.json()["accounts"] == []
    before = client.get(f"{base}/accounts/{card['id']}/balance", headers=auth(owner_token)).json()
    transactions = client.get(f"{base}/transactions", headers=auth(owner_token)).json()
    result = client.get(f"{base}/reports/debt-cost", headers=auth(owner_token))
    assert result.status_code == 200, result.text
    assert result.json()["model"] == "unchanged_balance_monthly_apr"
    assert result.json()["as_of"] == date.today().isoformat()
    rows = {row["account_id"]: row for row in result.json()["accounts"]}
    assert rows[card["id"]]["estimated_monthly_interest_minor"] == 100
    assert rows[unknown.json()["id"]]["estimated_monthly_interest_minor"] is None
    assert rows[unknown.json()["id"]]["missing_fields"] == ["annual_rate_basis_points"]
    # Current cost needs an explicit APR, not fabricated payment/due terms.
    saved = client.put(f"{base}/accounts/{card['id']}/debt-terms", headers=auth(owner_token), json={
        "terms_type": "credit_card", "annual_rate_basis_points": 1200,
        "promotional_rate_basis_points": 0, "promotional_ends_on": (date.today() + timedelta(days=30)).isoformat(),
    })
    assert saved.status_code == 200, saved.text
    filtered = client.get(f"{base}/reports/debt-cost?account_id={card['id']}", headers=auth(owner_token)).json()
    assert len(filtered["accounts"]) == 1
    assert filtered["accounts"][0]["effective_rate_basis_points"] == 0
    assert filtered["accounts"][0]["estimated_monthly_interest_minor"] == 0
    assert client.get(f"{base}/accounts/{card['id']}/balance", headers=auth(owner_token)).json() == before
    assert client.get(f"{base}/transactions", headers=auth(owner_token)).json() == transactions


def test_current_cost_filters_before_terms_balances_and_errors(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    base = f"/api/v1/budgets/{budget['id']}"
    visible = create_strategy_card(client, owner_token, budget["id"], "Visible", 10_000, 1200, 500)
    hidden = create_strategy_card(client, owner_token, budget["id"], "Private debt", 9_999_999, 9999, 500)
    child_id, child_token = add_child(session_factory, client)
    assert client.get(f"{base}/reports/debt-cost", headers=auth(child_token)).status_code == 404
    assert client.put(f"{base}/grants", headers=auth(owner_token), json={"user_id": child_id, "permission": "view"}).status_code == 200
    access = {"capabilities": ["view_budget", "view_accounts", "view_reports", "view_account_balances"],
              "restrict_accounts": True, "account_ids": [visible["id"]], "restrict_categories": False, "category_ids": []}
    assert client.put(f"{base}/access/{child_id}", headers=auth(owner_token), json=access).status_code == 200
    path = f"{base}/reports/debt-cost"
    response = client.get(path, headers=auth(child_token))
    assert response.status_code == 200
    assert [row["account_id"] for row in response.json()["accounts"]] == [visible["id"]]
    assert hidden["id"] not in response.text and "Private debt" not in response.text
    foreign_budget = create_budget(client, owner_token, session_factory)
    foreign = create_strategy_card(client, owner_token, foreign_budget["id"], "Foreign", 1000, 500, 100)
    for inaccessible in (hidden["id"], foreign["id"], "missing"):
        denied = client.get(f"{path}?account_id={inaccessible}", headers=auth(child_token))
        assert denied.status_code == 404
        assert denied.json() == {"detail": "Report resource not found"}
    access["capabilities"].remove("view_account_balances")
    assert client.put(f"{base}/access/{child_id}", headers=auth(owner_token), json=access).status_code == 200
    assert client.get(path, headers=auth(child_token)).status_code == 403
    assert client.get(path, headers=auth("expired")).status_code == 401
