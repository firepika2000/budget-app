"""Month-scoped metadata affects guidance, never accounting or target identity."""
from datetime import date

from sqlalchemy import select

from app.models import Category, CategoryGroup, CategoryTargetSnooze
from .conftest import auth
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child
from .test_targets_contract import grant_scoped_planner


def test_snooze_month_isolation_reload_resume_and_delete(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    base = f"/api/v1/budgets/{budget['id']}"
    target_url = f"{base}/categories/{category['id']}/target"
    snooze_url = f"{target_url}/snooze/2027-02-01"
    headers = auth(owner_token)
    target = {"target_type": "recurring_expense", "target_amount_minor": 120000,
              "target_date": "2027-01-31", "recurrence_months": 12, "minimum_contribution_minor": 15000}
    assert client.put(target_url, headers=headers, json=target).status_code == 200
    before = client.get(f"{base}/months/2027-02-01", headers=headers).json()
    balance = client.get(f"{base}/accounts/{account['id']}/balance", headers=headers).json()
    transactions = client.get(f"{base}/transactions", headers=headers).json()
    for _ in range(2):
        result = client.put(snooze_url, headers=headers, json={"is_snoozed": True})
        assert result.status_code == 200, result.text
        assert result.json()["is_snoozed"] is True
        summary = client.get(f"{base}/months/2027-02-01", headers=headers).json()
        row = summary["categories"][0]
        assert row["is_target_snoozed"] is True
        assert row["recommended_contribution_minor"] == row["underfunded_minor"] == 0
        assert row["target_date"] == "2028-01-31"
        for key in ("ready_to_assign_minor", "allocation_version", "total_assigned_minor", "total_overspent_minor"):
            assert summary[key] == before[key]
        for key in ("assigned_minor", "activity_minor", "available_minor", "carried_available_minor", "funded_credit_spending_minor"):
            assert row[key] == before["categories"][0][key]
        assert client.get(f"{base}/accounts/{account['id']}/balance", headers=headers).json() == balance
        assert client.get(f"{base}/transactions", headers=headers).json() == transactions
        assert client.get(f"{base}/smart-funding/2027-02-01", headers=headers).json()["proposals"] == []
        assert client.get(target_url, headers=headers).json()["is_active"] is True
        assert client.get(target_url, headers=headers).json()["target_date"] == target["target_date"]
    with session_factory() as db:
        records = list(db.scalars(select(CategoryTargetSnooze)))
        assert len(records) == 1
        assert records[0].month == date(2027, 2, 1)
        assert records[0].created_by_user_id
    for month in ("2027-01-01", "2027-03-01"):
        row = client.get(f"{base}/months/{month}", headers=headers).json()["categories"][0]
        assert row["is_target_snoozed"] is False
        assert row["recommended_contribution_minor"] > 0
    # Rule edits preserve the selected-month metadata.
    assert client.put(target_url, headers=headers, json={**target, "target_amount_minor": 240000}).status_code == 200
    assert client.get(f"{base}/months/2027-02-01", headers=headers).json()["categories"][0]["is_target_snoozed"]
    assert client.put(target_url, headers=headers, json={**target, "is_active": False}).status_code == 200
    assert client.get(f"{base}/months/2027-02-01", headers=headers).json()["categories"][0]["is_target_snoozed"]
    assert client.put(target_url, headers=headers, json={**target, "target_amount_minor": 240000}).status_code == 200
    for _ in range(2):
        assert client.put(snooze_url, headers=headers, json={"is_snoozed": False}).status_code == 200
    assert client.get(f"{base}/months/2027-02-01", headers=headers).json()["categories"][0]["recommended_contribution_minor"] == 20000
    assert client.put(snooze_url, headers=headers, json={"is_snoozed": True}).status_code == 200
    assert client.delete(target_url, headers=headers).status_code == 204
    with session_factory() as db:
        assert list(db.scalars(select(CategoryTargetSnooze))) == []
    assert client.put(target_url, headers=headers, json=target).status_code == 200
    assert client.get(f"{base}/months/2027-02-01", headers=headers).json()["categories"][0]["is_target_snoozed"] is False


def test_snooze_capability_scope_and_validation(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/target"
    assert client.put(path, headers=auth(owner_token), json={"target_type": "monthly_funding", "target_amount_minor": 10000}).status_code == 200
    member, token = add_child(session_factory, client)
    def grant(categories, capabilities):
        grant_scoped_planner(client, owner_token, budget["id"], member, account["id"], categories, capabilities)
    body = {"is_snoozed": True}
    grant([category["id"]], ["view_budget", "view_categories"])
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(token), json=body).status_code == 403
    grant([], ["view_budget", "view_categories", "manage_planning"])
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(token), json=body).status_code == 404
    grant([category["id"]], ["view_budget", "view_categories", "manage_planning"])
    assert client.put(f"{path}/snooze/2027-02-02", headers=auth(token), json=body).status_code == 422
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(token), json=body).status_code == 200
    grant([category["id"]], ["view_budget", "view_categories"])
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(token), json={"is_snoozed": False}).status_code == 403
    with session_factory() as db:
        assert len(list(db.scalars(select(CategoryTargetSnooze)))) == 1
    other = create_budget(client, owner_token, session_factory, name="Other")
    wrong = path.replace(budget["id"], other["id"])
    assert client.put(f"{wrong}/snooze/2027-02-01", headers=auth(owner_token), json=body).status_code == 404
    with session_factory() as db:
        db.get(Category, category["id"]).is_archived = True
        db.commit()
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(owner_token), json=body).status_code == 404
    with session_factory() as db:
        item = db.get(Category, category["id"])
        item.is_archived = False
        db.get(CategoryGroup, item.group_id).is_archived = True
        db.commit()
    assert client.put(f"{path}/snooze/2027-02-01", headers=auth(owner_token), json=body).status_code == 404
