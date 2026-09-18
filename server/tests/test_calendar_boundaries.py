from datetime import date

import pytest

from app.calendar_dates import month_periods

from .conftest import auth
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure


@pytest.mark.parametrize("start,end,expected", [
    ("2024-02-15", "2024-03-02", [("2024-02-15", "2024-02-29"), ("2024-03-01", "2024-03-02")]),
    ("1900-02-01", "1900-03-01", [("1900-02-01", "1900-02-28"), ("1900-03-01", "1900-03-01")]),
    ("2000-02-01", "2000-02-29", [("2000-02-01", "2000-02-29")]),
    ("1999-12-31", "2000-01-01", [("1999-12-31", "1999-12-31"), ("2000-01-01", "2000-01-01")]),
    ("9999-12-31", "9999-12-31", [("9999-12-31", "9999-12-31")]),
    ("2026-09-30", "2026-09-01", []),
])
def test_month_periods_are_inclusive_clipped_and_calendar_safe(start, end, expected):
    assert [(left.isoformat(), right.isoformat()) for left, right in
            month_periods(date.fromisoformat(start), date.fromisoformat(end))] == expected


@pytest.mark.parametrize("report", ["income-spending", "spending-trends", "net-worth", "debt", "plan-performance"])
@pytest.mark.parametrize("start,end", [("9999-12-01", "9999-12-31"), ("0001-01-01", "0001-01-31")])
def test_reports_handle_supported_calendar_endpoints(client, owner_token, session_factory, report, start, end):
    budget = create_budget(client, owner_token, session_factory)
    create_budget_structure(client, owner_token, budget["id"])
    response = client.get(f"/api/v1/budgets/{budget['id']}/reports/{report}", headers=auth(owner_token),
                          params={"start_date": start, "end_date": end})
    assert response.status_code == 200, response.text
    assert response.json()["start_date"] == start
    assert response.json()["end_date"] == end


def test_last_supported_planning_month_preserves_exact_assignment_and_funding(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=50000)
    root = f"/api/v1/budgets/{budget['id']}"
    headers = auth(owner_token)
    assigned = client.put(f"{root}/categories/{category['id']}/assignment", headers=headers,
                          json={"month": "9999-12-01", "assigned_minor": 20000})
    assert assigned.status_code == 200, assigned.text
    summary = client.get(f"{root}/months/9999-12-01", headers=headers)
    assert summary.status_code == 200, summary.text
    assert summary.json()["categories"][0]["available_minor"] == 20000
    assert summary.json()["ready_to_assign_minor"] == 30000
    assert client.put(f"{root}/categories/{category['id']}/target", headers=headers,
                      json={"target_type": "monthly_funding", "target_amount_minor": 30000}).status_code == 200
    preview = client.get(f"{root}/smart-funding/9999-12-01", headers=headers)
    assert preview.status_code == 200, preview.text
    assert preview.json()["proposed_minor"] == 10000
    result = client.post(f"{root}/smart-funding", headers=headers, json={
        "month": "9999-12-01", "expected_allocation_version": preview.json()["allocation_version"],
    })
    assert result.status_code == 201, result.text
    assert client.get(f"{root}/months/9999-12-01", headers=headers).json()["ready_to_assign_minor"] == 20000
