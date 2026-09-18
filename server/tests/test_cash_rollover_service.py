"""Real ledger/service consumers must agree on derived month-boundary effects."""
from datetime import date

from app.allocation import category_available_balance, ready_to_assign_balance
from app.cash_rollover_repository import cash_rollover_effects
from app.models import CashRolloverPolicyChange, CreditCardReserveEvent, User
from .conftest import auth, freeze_today
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_delegated_access import add_child


def policy(factory, budget_id, effective=date(2026, 10, 1), version=1, value="absorb_next_month"):
    with factory() as db:
        db.add(CashRolloverPolicyChange(budget_id=budget_id, effective_month=effective,
            policy=value, version=version, source="user_selection", actor_user_id=db.query(User.id).first()[0]))
        db.commit()


def setup(client, token, factory):
    budget = create_budget(client, token, factory)
    account, category = create_budget_structure(client, token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    record(client, token, budget["id"], account_id=account["id"], amount_minor=50000, occurred_on="2026-09-01")
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(token),
        json={"month": "2026-09-01", "assigned_minor": 10000}).status_code == 200
    record(client, token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-15000, occurred_on="2026-09-02")
    policy(factory, budget["id"])
    return budget, account, category, root


def test_absorption_service_reports_guards_and_read_neutrality(client, owner_token, session_factory):
    budget, account, category, root = setup(client, owner_token, session_factory)
    headers = auth(owner_token)
    paths = [f"{root}/transactions", f"{root}/allocations", f"{root}/accounts/{account['id']}/balance"]
    before = {path: client.get(path, headers=headers).json() for path in paths}
    for _ in range(2):
        sept = client.get(f"{root}/months/2026-09-01", headers=headers).json()
        oct = client.get(f"{root}/months/2026-10-01", headers=headers).json()
        assert sept["ready_to_assign_minor"] == 40000
        assert sept["all_date_unassigned_minor"] == 35000
        assert sept["categories"][0]["available_minor"] == -5000
        assert oct["ready_to_assign_minor"] == 35000
        assert {key: oct["categories"][0][key] for key in ("carried_available_minor", "assigned_minor", "activity_minor", "available_minor")} == dict.fromkeys(("carried_available_minor", "assigned_minor", "activity_minor", "available_minor"), 0)
        report = client.get(f"{root}/reports/plan-performance?start_date=2026-09-01&end_date=2026-11-30", headers=headers)
        assert report.status_code == 200, report.text
        assert [(p["ready_to_assign_minor"], p["assigned_minor"], p["activity_minor"], p["available_minor"]) for p in report.json()["points"]] == [(40000, 10000, -15000, -5000), (35000, 0, 0, 0), (35000, 0, 0, 0)]
    assert {path: client.get(path, headers=headers).json() for path in paths} == before
    with session_factory() as db:
        assert ready_to_assign_balance(db, budget["id"]) == 35000
        assert category_available_balance(db, budget["id"], category["id"], date(2026, 9, 30)) == -5000
        assert category_available_balance(db, budget["id"], category["id"], date(2026, 10, 1)) == 0
    # The selected historical month must not make globally consumed money assignable again.
    denied = client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
        json={"month": "2026-10-01", "assigned_minor": 35001})
    assert denied.status_code == 409, denied.text
    assert {path: client.get(path, headers=headers).json() for path in paths} == before


def test_latest_pending_policy_and_historical_effects(client, owner_token, session_factory):
    budget, _, category, _ = setup(client, owner_token, session_factory)
    policy(session_factory, budget["id"], version=2, value="carry_category_deficit")
    with session_factory() as db:
        assert cash_rollover_effects(db, budget["id"]) == []
        assert category_available_balance(db, budget["id"], category["id"]) == -5000
    policy(session_factory, budget["id"], effective=date(2026, 11, 1), version=3)
    policy(session_factory, budget["id"], effective=date(2026, 12, 1), version=4, value="carry_category_deficit")
    with session_factory() as db:
        effects = cash_rollover_effects(db, budget["id"])
        assert [(item.month, item.amount_minor, item.policy_version) for item in effects] == [(date(2026, 11, 1), 5000, 3)]
        assert cash_rollover_effects(db, budget["id"], category_ids=set()) == []


def test_credit_deficit_is_not_absorbed_and_hidden_account_cannot_leak_effect(client, owner_token, session_factory):
    budget, account, category, root = setup(client, owner_token, session_factory)
    card = create_credit_card(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-3000, occurred_on="2026-09-03")
    with session_factory() as db:
        assert sum(item.amount_minor for item in cash_rollover_effects(db, budget["id"])) == 5000
        assert category_available_balance(db, budget["id"], category["id"]) == -3000
    member, token = add_child(session_factory, client)
    assert client.put(f"{root}/grants", headers=auth(owner_token), json={"user_id": member, "permission": "contribute"}).status_code == 200
    assert client.put(f"{root}/access/{member}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_reports"], "restrict_accounts": True, "account_ids": [card["id"]],
        "restrict_categories": True, "category_ids": [category["id"]]}).status_code == 200
    response = client.get(f"{root}/months/2026-10-01", headers=auth(token))
    assert response.status_code == 200, response.text
    assert response.json()["categories"][0]["carried_available_minor"] == 7000
    assert response.json()["ready_to_assign_minor"] == 0
    assert response.json()["all_date_unassigned_minor"] is None
    report = client.get(f"{root}/reports/plan-performance?start_date=2026-10-01&end_date=2026-10-31", headers=auth(token))
    assert report.status_code == 200, report.text
    assert report.json()["points"][0]["carried_available_minor"] == 7000
    assert report.json()["points"][0]["ready_to_assign_minor"] == 0


def test_after_boundary_card_funding_and_historical_refund_use_canonical_balances(client, owner_token, session_factory, monkeypatch):
    from app import budgeting_routes
    freeze_today(monkeypatch, date(2026, 10, 15), budgeting_routes)
    budget, account, category, root = setup(client, owner_token, session_factory)
    card = create_credit_card(client, owner_token, budget["id"])
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
        json={"month": "2026-10-01", "assigned_minor": 10000}).status_code == 200
    purchase = record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"],
        amount_minor=-8000, occurred_on="2026-10-02")
    with session_factory() as db:
        assert db.query(CreditCardReserveEvent.amount_minor).filter_by(source_transaction_id=purchase["id"]).scalar() == 8000
        assert category_available_balance(db, budget["id"], category["id"], date(2026, 10, 31)) == 2000
        assert ready_to_assign_balance(db, budget["id"]) == 25000
    # Correct a historical cash fact: recompute the old policy amount, not a new allocation.
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
        amount_minor=2000, occurred_on="2026-09-04")
    with session_factory() as db:
        assert sum(item.amount_minor for item in cash_rollover_effects(db, budget["id"])) == 3000
        assert ready_to_assign_balance(db, budget["id"]) == 27000
        assert category_available_balance(db, budget["id"], category["id"]) == 2000
        assert db.query(CreditCardReserveEvent.amount_minor).filter_by(source_transaction_id=purchase["id"]).scalar() == 8000


def test_hidden_card_reserves_do_not_leak_into_account_scoped_reports(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=50000, occurred_on="2026-09-01")
    assert client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 10000}).status_code == 200
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-8000, occurred_on="2026-09-02")
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-15000, occurred_on="2026-09-03")
    policy(session_factory, budget["id"])
    member, token = add_child(session_factory, client)
    assert client.put(f"{root}/grants", headers=auth(owner_token), json={"user_id": member, "permission": "contribute"}).status_code == 200
    assert client.put(f"{root}/access/{member}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_reports"], "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": False, "category_ids": []}).status_code == 200
    for month in ("2026-09-01", "2026-10-01"):
        summary = client.get(f"{root}/months/{month}", headers=auth(token))
        assert summary.status_code == 200, summary.text
        payment = next(row for row in summary.json()["categories"] if row["category_id"] == card["payment_category_id"])
        assert payment["available_minor"] == payment["activity_minor"] == 0
    report = client.get(f"{root}/reports/plan-performance?start_date=2026-09-01&end_date=2026-10-31", headers=auth(token))
    assert report.status_code == 200, report.text
    assert [(row["available_minor"], row["activity_minor"]) for row in report.json()["points"]] == [(-5000, -15000), (0, 0)]
