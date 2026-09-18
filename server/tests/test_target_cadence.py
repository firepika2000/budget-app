"""Selected-month target guidance must advance cadence without editing its anchor."""
from datetime import date
import json
from pathlib import Path

import pytest

from app.models import CategoryTarget
from app.planning import target_funding
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure
from .test_allocation_ledger import fund


def test_annual_target_after_due_month_uses_next_occurrence():
    target = CategoryTarget(
        target_type="recurring_expense", target_amount_minor=120000,
        target_date=date(2027, 1, 31), recurrence_months=12,
        minimum_contribution_minor=0, is_active=True,
    )
    result = target_funding(
        target, month=date(2027, 2, 1), assigned_minor=0, available_minor=0,
    )
    assert result.recommended_contribution_minor == 10000
    assert result.underfunded_minor == 10000
    assert target.target_date == date(2027, 1, 31)


@pytest.mark.parametrize("vector", json.loads(Path(__file__).with_name("target_cadence_vectors.json").read_text()), ids=lambda v: v["name"])
def test_shared_target_vectors(vector):
    anchor = date.fromisoformat(vector["anchor"])
    target = CategoryTarget(
        target_type=vector.get("type", "recurring_expense"),
        target_amount_minor=vector.get("amount", 120000), target_date=anchor,
        recurrence_months=vector["cadence"], minimum_contribution_minor=vector.get("minimum", 0),
        is_active=vector.get("active", True),
    )
    result = target_funding(target, month=date.fromisoformat(vector["month"]),
                            assigned_minor=vector.get("assigned", 0), available_minor=vector.get("available", 0))
    assert result.recommended_contribution_minor == vector["recommended"]
    assert result.underfunded_minor == vector.get("underfunded", vector["recommended"])
    assert (result.effective_target_date.isoformat() if result.effective_target_date else None) == vector["due"]
    assert target.target_date == anchor


def test_live_month_and_smart_funding_use_next_due_without_mutating_money(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    base = f"/api/v1/budgets/{budget['id']}"
    headers = auth(owner_token)
    before = client.get(f"{base}/months/2027-02-01", headers=headers).json()
    transactions = client.get(f"{base}/transactions", headers=headers).json()
    target_path = f"{base}/categories/{category['id']}/target"
    saved = client.put(target_path, headers=headers, json={
        "target_type": "recurring_expense", "target_amount_minor": 120000,
        "target_date": "2027-01-31", "recurrence_months": 12,
    })
    assert saved.status_code == 200
    for _ in range(2):
        response = client.get(f"{base}/months/2027-02-01", headers=headers)
        assert response.status_code == 200
        after = response.json()
        row = next(r for r in after["categories"] if r["category_id"] == category["id"])
        assert row["target_date"] == "2028-01-31"
        assert row["recommended_contribution_minor"] == 10000
        assert row["underfunded_minor"] == 10000
        assert after["ready_to_assign_minor"] == before["ready_to_assign_minor"]
        old = next(r for r in before["categories"] if r["category_id"] == category["id"])
        for key in ("assigned_minor", "activity_minor", "available_minor", "carried_available_minor",
                    "funded_credit_spending_minor", "credit_overspent_minor", "cash_overspent_minor"):
            assert row[key] == old[key]
        preview = client.get(f"{base}/smart-funding/2027-02-01", headers=headers)
        assert preview.status_code == 200
        assert preview.json()["proposals"][0]["amount_minor"] == 10000
        assert client.get(target_path, headers=headers).json()["target_date"] == "2027-01-31"
        assert client.get(f"{base}/transactions", headers=headers).json() == transactions
