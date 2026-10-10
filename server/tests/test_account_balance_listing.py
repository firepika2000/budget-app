from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child, configure_child


def test_balance_pages_match_individual_exact_observations_and_scope(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    other = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                        json={"name": "Private", "account_type": "checking", "is_on_budget": True}).json()
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
           amount_minor=9007199254740993, is_cleared=True)
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
           amount_minor=-100, is_cleared=False)
    url = f"/api/v1/budgets/{budget['id']}"
    for cutoff in [None, "2026-09-03", "2026-09-04"]:
        params = {} if cutoff is None else {"through_date": cutoff}
        pages = [client.get(f"{url}/account-balances", headers=auth(owner_token),
                            params={**params, "limit": 1, "offset": offset}) for offset in range(3)]
        assert all(page.status_code == 200 for page in pages)
        rows = [row for page in pages for row in page.json()]
        assert [row["account_id"] for row in rows] == sorted([account["id"], other["id"]])
        for row in rows:
            assert row == client.get(f"{url}/accounts/{row['account_id']}/balance",
                                     headers=auth(owner_token), params=params).json()
        assert pages[-1].json() == []
    current = client.get(f"{url}/account-balances", headers=auth(owner_token)).json()
    observed = next(row for row in current if row["account_id"] == account["id"])
    assert observed["cleared_balance_minor"] == 9007199254740993
    assert observed["uncleared_balance_minor"] == -100
    assert observed["working_balance_minor"] == 9007199254740893
    for params in [{"limit": 201}, {"offset": -1}]:
        assert client.get(f"{url}/account-balances", headers=auth(owner_token), params=params).status_code == 422
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, account["id"], category["id"])
    assert client.get(f"{url}/account-balances", headers=auth(child_token)).status_code == 403
    granted = client.put(f"{url}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_account_balances"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [category["id"]],
    })
    assert granted.status_code == 200, granted.text
    restricted = client.get(f"{url}/account-balances", headers=auth(child_token))
    assert restricted.status_code == 200, restricted.text
    assert [row["account_id"] for row in restricted.json()] == [account["id"]]
    assert other["id"] not in restricted.text
