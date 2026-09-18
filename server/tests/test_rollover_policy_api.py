from datetime import date

import pytest

from app import rollover_routes
from .conftest import auth, freeze_today
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure, add_member


@pytest.mark.parametrize("policy, expected_future_rta", [
    ("absorb_next_month", 8000), ("carry_category_deficit", 10000),
])
def test_explicit_creation_policy_has_owner_provenance_and_exact_projection(
    client, owner_token, session_factory, policy, expected_future_rta,
):
    from app.models import Household
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    response = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id, "name": "Explicit policy", "currency_code": "USD",
        "cash_rollover_policy": policy,
    })
    assert response.status_code == 201, response.text
    budget = response.json()
    root = f"/api/v1/budgets/{budget['id']}"
    observation = client.get(root + "/cash-rollover-policy", headers=auth(owner_token)).json()
    assert observation["current_policy"] == policy
    assert observation["allocation_version"] == observation["policy_version"] == 0
    audit = client.get(root + "/cash-rollover-policy/history", headers=auth(owner_token)).json()["items"]
    assert len(audit) == 1
    assert audit[0]["source"] == "budget_creation" and audit[0]["actor_user_id"]
    assert audit[0]["effective_month"] == "0001-01-01"
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=10000, occurred_on="2026-09-01")
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2000, occurred_on="2026-09-02")
    result = client.get(root + "/months/2026-10-01", headers=auth(owner_token))
    assert result.status_code == 200, result.text
    assert result.json()["ready_to_assign_minor"] == expected_future_rta
    assert client.get(root + "/cash-rollover-policy/history", headers=auth(owner_token)).json()["items"] == audit


def test_invalid_creation_policy_does_not_create_budget(client, owner_token, session_factory):
    from app.models import Household
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    before = client.get("/api/v1/budgets", headers=auth(owner_token)).json()
    result = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id, "name": "Invalid", "currency_code": "USD", "cash_rollover_policy": "unknown",
    })
    assert result.status_code == 422
    assert client.get("/api/v1/budgets", headers=auth(owner_token)).json() == before


def test_policy_lifecycle_is_prospective_audited_and_invalidates_allocations(client, owner_token, session_factory, monkeypatch):
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    url = f"{root}/cash-rollover-policy"
    headers = auth(owner_token)
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=10000)
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2000)
    paths = [f"{root}/transactions", f"{root}/allocations", f"{root}/accounts/{account['id']}/balance"]
    before = {path: client.get(path, headers=headers).json() for path in paths}
    assert client.get(url, headers=headers).json()["current_policy"] == "carry_category_deficit"
    body = {"policy": "absorb_next_month", "effective_month": "2026-10-01", "expected_policy_version": 0, "expected_allocation_version": 0}
    selected = client.put(url, headers=headers, json=body)
    assert selected.status_code == 200, selected.text
    assert selected.json()["policy_version"] == selected.json()["allocation_version"] == 1
    assert selected.json()["current_policy"] == "carry_category_deficit"
    assert selected.json()["pending"] == [{"effective_month": "2026-10-01", "policy": "absorb_next_month", "version": 1}]
    freeze_today(monkeypatch, date(2026, 10, 1), rollover_routes)
    activated = client.get(url, headers=headers).json()
    assert activated["current_policy"] == "absorb_next_month" and activated["pending"] == []
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    assert client.get(f"{root}/months/2026-09-01", headers=headers).json()["ready_to_assign_minor"] == 10000
    assert client.get(f"{root}/months/2026-10-01", headers=headers).json()["ready_to_assign_minor"] == 8000
    assert client.put(url, headers=headers, json=body).status_code == 409
    stale = client.put(f"{root}/categories/{category['id']}/assignment", headers=headers, json={
        "month": "2026-10-01", "assigned_minor": 1000, "expected_allocation_version": 0})
    assert stale.status_code == 409, stale.text
    stale_funding = client.post(f"{root}/smart-funding", headers=headers, json={
        "month": "2026-10-01", "expected_allocation_version": 0})
    assert stale_funding.status_code == 409, stale_funding.text
    assert stale_funding.json()["detail"]["current_allocation_version"] == 1
    body.update(expected_policy_version=1, expected_allocation_version=1)
    assert client.put(url, headers=headers, json=body).json()["policy_version"] == 1  # no-op
    body["policy"] = "carry_category_deficit"
    changed = client.put(url, headers=headers, json=body)
    assert changed.status_code == 200, changed.text
    assert changed.json()["policy_version"] == 2
    audit = client.get(url + "/history?limit=1", headers=headers).json()
    assert len(audit["items"]) == 1 and audit["next_before_version"] == 2
    assert audit["items"][0]["source"] == "user_selection" and audit["items"][0]["actor_user_id"]
    older = client.get(url + "/history?before_version=2", headers=headers).json()["items"]
    assert [row["version"] for row in older] == [1, 0]
    assert older[-1]["source"] == "legacy_migration" and older[-1]["actor_user_id"] is None
    # The allocation token changes, but no financial operation/transaction is manufactured.
    after = {path: client.get(path, headers=headers).json() for path in paths}
    assert after == before
    freeze_today(monkeypatch, date(2026, 10, 1), rollover_routes)
    assert client.get(url, headers=headers).json()["pending"] == []
    assert client.get(url, headers=headers).json()["current_policy"] == "carry_category_deficit"


@pytest.mark.parametrize("effective", ["2026-08-01", "2026-09-01", "2026-10-02"])
def test_policy_rejects_nonprospective_changes_without_history(client, owner_token, session_factory, monkeypatch, effective):
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    budget = create_budget(client, owner_token, session_factory)
    url = f"/api/v1/budgets/{budget['id']}/cash-rollover-policy"
    result = client.put(url, headers=auth(owner_token), json={"policy": "absorb_next_month", "effective_month": effective,
        "expected_policy_version": 0, "expected_allocation_version": 0})
    assert result.status_code == 422, result.text
    assert client.get(url + "/history", headers=auth(owner_token)).json()["items"] == []


def test_policy_authorization_and_stale_policy_version(client, owner_token, session_factory, monkeypatch):
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    budget = create_budget(client, owner_token, session_factory)
    url = f"/api/v1/budgets/{budget['id']}/cash-rollover-policy"
    member = add_member(session_factory, client, "manage", budget["id"])
    body = {"policy": "absorb_next_month", "effective_month": "2026-10-01", "expected_policy_version": 0, "expected_allocation_version": 0}
    for path in (url, url + "/history"):
        assert client.get(path, headers=auth(member)).status_code == 403
        assert client.get(path).status_code == 401
    assert client.put(url, headers=auth(member), json=body).status_code == 403
    other = create_budget(client, owner_token, session_factory, "Private")
    assert client.get(f"/api/v1/budgets/{other['id']}/cash-rollover-policy", headers=auth(member)).status_code == 404
    body["expected_policy_version"] = 99
    assert client.put(url, headers=auth(owner_token), json=body).status_code == 409


def test_policy_projection_failure_rolls_back_history_and_versions(client, owner_token, session_factory, monkeypatch):
    freeze_today(monkeypatch, date(2026, 9, 18), rollover_routes)
    budget = create_budget(client, owner_token, session_factory)
    url = f"/api/v1/budgets/{budget['id']}/cash-rollover-policy"
    before = client.get(url, headers=auth(owner_token)).json()
    # Exercise failure after flush, not merely request validation before any write.
    monkeypatch.setattr(rollover_routes, "ready_to_assign_balance", lambda *args: 2**63)
    result = client.put(url, headers=auth(owner_token), json={"policy": "absorb_next_month",
        "effective_month": "2026-10-01", "expected_policy_version": 0, "expected_allocation_version": 0})
    assert result.status_code == 422, result.text
    assert client.get(url, headers=auth(owner_token)).json() == before
    assert client.get(url + "/history", headers=auth(owner_token)).json()["items"] == []
