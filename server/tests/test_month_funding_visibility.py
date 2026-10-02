"""Global spendable observations must never leak through a restricted monthly view."""
from .conftest import auth
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child


def test_month_global_funding_observations_require_unrestricted_balance_visibility(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=123456)
    root = f"/api/v1/budgets/{budget['id']}"
    member_id, token = add_child(session_factory, client)
    assert client.put(f"{root}/grants", headers=auth(owner_token), json={"user_id": member_id, "permission": "contribute"}).status_code == 200
    url = f"{root}/months/2026-09-01"
    cases = [
        # Account/category scoping always wins over the household-total capability.
        (True, False, True, True, False),
        (False, True, True, True, False),
        (True, True, True, True, False),
        # Both the explicit total capability and balance visibility are required for all-date RTA.
        (False, False, False, True, True),
        (False, False, True, False, False),
        (False, False, True, True, True),
    ]
    for account_scope, category_scope, balances, totals, visible in cases:
        response = client.put(f"{root}/access/{member_id}", headers=auth(owner_token), json={
            "capabilities": ["view_budget", "view_reports"]
                + (["view_account_balances"] if balances else [])
                + (["view_budget_totals"] if totals else []),
            "restrict_accounts": account_scope, "account_ids": [account["id"]] if account_scope else [],
            "restrict_categories": category_scope, "category_ids": [category["id"]] if category_scope else [],
        })
        assert response.status_code == 200, response.text
        result = client.get(url, headers=auth(token))
        assert result.status_code == 200, result.text
        assert result.json()["budget_totals_visible"] is visible
        assert result.json()["ready_to_assign_minor"] == (123456 if visible else 0)
        expected = 123456 if visible and balances else None
        assert result.json()["all_date_unassigned_minor"] == expected
        assert result.json()["funding_limit_minor"] == expected
    assert client.get(url).status_code == 401
    other = create_budget(client, owner_token, session_factory, name="Private")
    assert client.get(f"/api/v1/budgets/{other['id']}/months/2026-09-01", headers=auth(token)).status_code == 404
