from sqlalchemy import select

from app.models import DebtPayoffPlan
from .conftest import auth
from .test_budgeting_api import create_budget
from .test_debt_projection import create_strategy_card
from .test_delegated_access import add_child


def test_payoff_plan_round_trip_is_per_user_and_money_neutral(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    first = create_strategy_card(client, owner_token, budget["id"], "High APR", 50_000, 2_400, 5_000)
    second = create_strategy_card(client, owner_token, budget["id"], "Small balance", 20_000, 1_200, 2_000)
    base = f"/api/v1/budgets/{budget['id']}"
    before = {
        account["id"]: client.get(f"{base}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
        for account in (first, second)
    }

    assert client.get(f"{base}/debt-payoff-plan", headers=auth(owner_token)).json() is None
    payload = {
        "strategy": "custom", "rollover": True, "extra_payment_minor": 12_345,
        "account_ids": [first["id"], second["id"]],
        "custom_order": [second["id"], first["id"]], "target_date": "2028-12-31",
    }
    saved = client.put(f"{base}/debt-payoff-plan", headers=auth(owner_token), json=payload)
    assert saved.status_code == 200, saved.text
    assert saved.json()["id"]
    assert {key: saved.json()[key] for key in payload} == payload
    assert client.get(f"{base}/debt-payoff-plan", headers=auth(owner_token)).json() == saved.json()

    updated = client.put(f"{base}/debt-payoff-plan", headers=auth(owner_token), json={
        "strategy": "snowball", "rollover": False, "extra_payment_minor": 0,
        "account_ids": [first["id"], second["id"]], "custom_order": [], "target_date": None,
    })
    assert updated.status_code == 200
    assert updated.json()["id"] == saved.json()["id"]
    after = {
        account["id"]: client.get(f"{base}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
        for account in (first, second)
    }
    assert after == before

    assert client.delete(f"{base}/debt-payoff-plan", headers=auth(owner_token)).status_code == 204
    assert client.get(f"{base}/debt-payoff-plan", headers=auth(owner_token)).json() is None


def test_payoff_plan_validates_scope_and_never_leaks_another_users_plan(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    visible = create_strategy_card(client, owner_token, budget["id"], "Visible", 5_000, 1_200, 500)
    hidden = create_strategy_card(client, owner_token, budget["id"], "Hidden", 8_000, 2_000, 700)
    base = f"/api/v1/budgets/{budget['id']}"
    owner_plan = {
        "strategy": "custom", "rollover": True, "extra_payment_minor": 500,
        "account_ids": [visible["id"], hidden["id"]],
        "custom_order": [hidden["id"], visible["id"]], "target_date": None,
    }
    assert client.put(f"{base}/debt-payoff-plan", headers=auth(owner_token), json=owner_plan).status_code == 200

    child_id, child_token = add_child(session_factory, client)
    assert client.put(f"{base}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "manage",
    }).status_code == 200
    assert client.put(f"{base}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_account_balances", "view_reports", "manage_planning"],
        "restrict_accounts": True, "account_ids": [visible["id"]],
        "restrict_categories": False, "category_ids": [],
    }).status_code == 200

    # Plans are personal: another member cannot infer the owner's plan or hidden account.
    child_get = client.get(f"{base}/debt-payoff-plan", headers=auth(child_token))
    assert child_get.status_code == 200
    assert child_get.json() is None
    denied = client.put(f"{base}/debt-payoff-plan", headers=auth(child_token), json={
        "strategy": "avalanche", "rollover": True, "extra_payment_minor": 0,
        "account_ids": [hidden["id"]], "custom_order": [], "target_date": None,
    })
    assert denied.status_code == 404
    assert hidden["id"] not in denied.text

    allowed = client.put(f"{base}/debt-payoff-plan", headers=auth(child_token), json={
        "strategy": "avalanche", "rollover": True, "extra_payment_minor": 100,
        "account_ids": [visible["id"]], "custom_order": [], "target_date": None,
    })
    assert allowed.status_code == 200, allowed.text
    assert allowed.json()["user_id"] == child_id
    assert client.get(f"{base}/debt-payoff-plan", headers=auth(owner_token)).json()["user_id"] != child_id

    with session_factory() as db:
        assert len(list(db.scalars(select(DebtPayoffPlan)))) == 2


def test_payoff_plan_rejects_invalid_orders_and_requires_capabilities(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    card = create_strategy_card(client, owner_token, budget["id"], "Card", 5_000, 1_200, 500)
    base = f"/api/v1/budgets/{budget['id']}"
    malformed = client.put(f"{base}/debt-payoff-plan", headers=auth(owner_token), json={
        "strategy": "custom", "rollover": True, "extra_payment_minor": 0,
        "account_ids": [card["id"]], "custom_order": [], "target_date": None,
    })
    assert malformed.status_code == 422

    child_id, child_token = add_child(session_factory, client)
    assert client.put(f"{base}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "view",
    }).status_code == 200
    assert client.get(f"{base}/debt-payoff-plan", headers=auth(child_token)).status_code == 200
    denied = client.put(f"{base}/debt-payoff-plan", headers=auth(child_token), json={
        "strategy": "avalanche", "rollover": True, "extra_payment_minor": 0,
        "account_ids": [], "custom_order": [], "target_date": None,
    })
    assert denied.status_code == 403
    assert client.delete(f"{base}/debt-payoff-plan", headers=auth(child_token)).status_code == 403


def test_malformed_payoff_plan_preserves_existing_scenario(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    card = create_strategy_card(client, owner_token, budget["id"], "Card", 5_000, 1_200, 500)
    path = f"/api/v1/budgets/{budget['id']}/debt-payoff-plan"
    valid = {
        "strategy": "snowball", "rollover": True, "extra_payment_minor": 2500,
        "account_ids": [card["id"]], "custom_order": [], "target_date": "2028-02-29",
    }
    saved = client.put(path, headers=auth(owner_token), json=valid)
    assert saved.status_code == 200
    before = saved.json()
    malformed = [
        {"strategy": "unknown"},
        {"extra_payment_minor": -1},
        {"account_ids": [card["id"], card["id"]]},
        {"strategy": "custom", "custom_order": []},
        {"custom_order": [card["id"]]},
        {"target_date": "2026-02-30"},
        {"account_ids": [str(index) for index in range(101)]},
    ]
    for changes in malformed:
        assert client.put(path, headers=auth(owner_token), json=valid | changes).status_code == 422
        assert client.get(path, headers=auth(owner_token)).json() == before
