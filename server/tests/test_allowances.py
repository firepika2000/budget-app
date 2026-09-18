from app.allowance_routes import advance_issue_date
from app.models import AllowanceIssuance, AllocationOperation
from datetime import date
import pytest

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child, configure_child


@pytest.mark.parametrize("hide_destination", [False, True])
def test_scoped_allowance_manager_cannot_read_or_mutate_hidden_resources(client, owner_token, session_factory, hide_destination):
    from app.models import CapabilityGrant, ResourceGrant
    budget, _, token, source, spending, _, plan, version = setup_allowance(client, owner_token, session_factory, "rollover")
    with session_factory() as db:
        child_id = plan["delegated_user_id"]
        db.add(CapabilityGrant(budget_id=budget["id"], user_id=child_id, capability="manage_allowances"))
        if hide_destination:
            db.add(ResourceGrant(budget_id=budget["id"], user_id=child_id, resource_type="category", resource_id=source["id"]))
            db.query(ResourceGrant).filter_by(budget_id=budget["id"], user_id=child_id, resource_type="category", resource_id=spending["id"]).delete()
        db.commit()
    root = f"/api/v1/budgets/{budget['id']}/allowances"
    before = summary_by_id(client, owner_token, budget["id"])
    assert client.get(root, headers=auth(token)).json() == []
    assert client.get(root + "?include_inactive=true", headers=auth(token)).json() == []
    create_body = {key: plan[key] for key in ("delegated_user_id", "source_category_id", "name", "amount_minor", "next_issue_date", "recurrence_unit", "interval_count", "rollover_policy", "splits")}
    assert client.post(root, headers=auth(token), json=create_body).status_code == 404
    assert client.get(root + f"/{plan['id']}/issuances", headers=auth(token)).status_code == 404
    assert client.patch(root + f"/{plan['id']}/status", headers=auth(token), json={"is_active": False}).status_code == 404
    assert client.delete(root + f"/{plan['id']}", headers=auth(token)).status_code == 404
    denied = client.post(root + f"/{plan['id']}/issue", headers=auth(token), json={"issue_date": plan["next_issue_date"], "expected_allocation_version": version})
    assert denied.status_code == 404, denied.text
    assert summary_by_id(client, owner_token, budget["id"]) == before
    with session_factory() as db:
        db.add(ResourceGrant(budget_id=budget["id"], user_id=child_id, resource_type="category",
            resource_id=spending["id"] if hide_destination else source["id"]))
        db.commit()
    assert len(client.get(root, headers=auth(token)).json()) == 1
    issue(client, token, budget["id"], plan["id"], plan["next_issue_date"], version)


def delegated_category(client, owner_token, budget_id, child_id, name):
    group = client.post(
        f"/api/v1/budgets/{budget_id}/category-groups",
        headers=auth(owner_token),
        json={"name": f"{name} group"},
    ).json()
    response = client.post(
        f"/api/v1/budgets/{budget_id}/categories",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": name, "delegated_user_id": child_id},
    )
    assert response.status_code == 201, response.text
    return response.json()


def setup_allowance(client, owner_token, session_factory, rollover_policy):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    child_id, child_token = add_child(session_factory, client)
    source = add_category(client, owner_token, budget["id"], "Family", "Allowance Pool")
    spending = delegated_category(
        client, owner_token, budget["id"], child_id, "Child Spending"
    )
    savings = delegated_category(
        client, owner_token, budget["id"], child_id, "Child Savings"
    )
    configure_child(
        client, owner_token, budget["id"], child_id, checking["id"], [spending["id"], savings["id"]]
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=10000,
        occurred_on="2026-08-01",
        is_cleared=True,
    )
    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{source['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-08-01", "assigned_minor": 10000},
    ).json()
    created = client.post(
        f"/api/v1/budgets/{budget['id']}/allowances",
        headers=auth(owner_token),
        json={
            "delegated_user_id": child_id,
            "source_category_id": source["id"],
            "name": "Weekly allowance",
            "amount_minor": 2000,
            "next_issue_date": "2026-08-28",
            "recurrence_unit": "week",
            "interval_count": 1,
            "rollover_policy": rollover_policy,
            "splits": [
                {"destination_category_id": spending["id"], "amount_minor": 1500},
                {"destination_category_id": savings["id"], "amount_minor": 500},
            ],
        },
    )
    assert created.status_code == 201, created.text
    return (
        budget, checking, child_token, source, spending, savings, created.json(),
        assigned["allocation_version"],
    )


def issue(client, owner_token, budget_id, plan_id, issue_date, version):
    response = client.post(
        f"/api/v1/budgets/{budget_id}/allowances/{plan_id}/issue",
        headers=auth(owner_token),
        json={"issue_date": issue_date, "expected_allocation_version": version},
    )
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize("revocation", ["membership", "visibility", "delegation"])
def test_allowance_issue_revalidates_recipient_authority(client, owner_token, session_factory, revocation):
    from app.models import Category, Membership, ResourceGrant
    budget, _, _, _, spending, _, plan, version = setup_allowance(client, owner_token, session_factory, "rollover")
    before = summary_by_id(client, owner_token, budget["id"])
    with session_factory() as db:
        if revocation == "membership":
            db.query(Membership).filter_by(user_id=plan["delegated_user_id"]).update({"is_active": False})
        elif revocation == "visibility":
            db.query(ResourceGrant).filter_by(budget_id=budget["id"], user_id=plan["delegated_user_id"], resource_type="category", resource_id=spending["id"]).delete()
        else:
            db.get(Category, spending["id"]).delegated_user_id = None
        db.commit()
    result = client.post(f"/api/v1/budgets/{budget['id']}/allowances/{plan['id']}/issue",
        headers=auth(owner_token), json={"issue_date": plan["next_issue_date"], "expected_allocation_version": version})
    assert result.status_code == 409, result.text
    # Delegation metadata itself changed in one fixture; compare financial observations explicitly.
    after = summary_by_id(client, owner_token, budget["id"])
    assert after[0]["allocation_version"] == before[0]["allocation_version"]
    assert after[0]["ready_to_assign_minor"] == before[0]["ready_to_assign_minor"]
    assert {key: row["available_minor"] for key, row in after[1].items()} == {key: row["available_minor"] for key, row in before[1].items()}
    with session_factory() as db:
        assert db.query(AllowanceIssuance).count() == 0


def summary_by_id(client, owner_token, budget_id):
    summary = client.get(
        f"/api/v1/budgets/{budget_id}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    return summary, {item["category_id"]: item for item in summary["categories"]}


def test_rollover_allowance_accumulates_and_splits_without_creating_money(
    client, owner_token, session_factory
):
    budget, _, child_token, source, spending, savings, plan, version = setup_allowance(
        client, owner_token, session_factory, "rollover"
    )
    first = issue(client, owner_token, budget["id"], plan["id"], "2026-08-28", version)
    second = issue(
        client, owner_token, budget["id"], plan["id"], "2026-09-04", version + 1
    )
    assert first["next_issue_date"] == "2026-09-04"
    assert second["next_issue_date"] == "2026-09-11"
    assert first["reclaimed_minor"] == second["reclaimed_minor"] == 0

    summary, by_id = summary_by_id(client, owner_token, budget["id"])
    assert by_id[source["id"]]["available_minor"] == 6000
    assert by_id[spending["id"]]["available_minor"] == 3000
    assert by_id[savings["id"]]["available_minor"] == 1000
    assert summary["ready_to_assign_minor"] == 0
    assert sum(item["available_minor"] for item in by_id.values()) == 10000

    child_plans = client.get(
        f"/api/v1/budgets/{budget['id']}/allowances", headers=auth(child_token)
    ).json()
    assert [item["id"] for item in child_plans] == [plan["id"]]
    assert child_plans[0]["source_category_id"] is None


def test_use_it_or_lose_it_reclaims_unspent_authority_before_next_issue(
    client, owner_token, session_factory
):
    budget, checking, _, source, spending, savings, plan, version = setup_allowance(
        client, owner_token, session_factory, "use_it_or_lose_it"
    )
    issue(client, owner_token, budget["id"], plan["id"], "2026-08-28", version)
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        category_id=spending["id"],
        amount_minor=-200,
        occurred_on="2026-09-01",
        is_cleared=True,
    )
    second = issue(client, owner_token, budget["id"], plan["id"], "2026-09-04", version + 1)
    assert second["reclaimed_minor"] == 1800

    _, by_id = summary_by_id(client, owner_token, budget["id"])
    assert by_id[source["id"]]["available_minor"] == 7800
    assert by_id[spending["id"]]["available_minor"] == 1500
    assert by_id[savings["id"]]["available_minor"] == 500

    stale = client.post(
        f"/api/v1/budgets/{budget['id']}/allowances/{plan['id']}/issue",
        headers=auth(owner_token),
        json={"issue_date": "2026-09-04", "expected_allocation_version": version + 1},
    )
    assert stale.status_code == 409
    with session_factory() as db:
        issuances = db.query(AllowanceIssuance).filter_by(plan_id=plan["id"]).all()
        assert len(issuances) == 2
        operation = db.get(AllocationOperation, second["allocation_operation_id"])
        assert operation.source == "allowance"
        assert sum(posting.amount_minor for posting in operation.postings) == 0


def test_monthly_allowance_recurrence_is_calendar_safe():
    assert advance_issue_date(date(2026, 1, 31), "month", 1) == date(2026, 2, 28)
    assert advance_issue_date(date(2028, 1, 31), "month", 1) == date(2028, 2, 29)


def test_owner_can_manage_paused_allowance_without_forecast_or_money_mutation(
    client, owner_token, session_factory
):
    budget, _, child_token, _, _, _, plan, _ = setup_allowance(
        client, owner_token, session_factory, "rollover"
    )
    before = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    paused = client.delete(
        f"/api/v1/budgets/{budget['id']}/allowances/{plan['id']}", headers=auth(owner_token)
    )
    assert paused.status_code == 204
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/allowances", headers=auth(owner_token)
    ).json() == []
    management = client.get(
        f"/api/v1/budgets/{budget['id']}/allowances?include_inactive=true", headers=auth(owner_token)
    )
    assert management.status_code == 200
    assert management.json()[0]["is_active"] is False
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/allowances?include_inactive=true", headers=auth(child_token)
    ).status_code == 403
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/allowances", headers=auth(child_token)
    ).json() == []
    after = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    for field in ("ready_to_assign_minor", "allocation_version"):
        assert after[field] == before[field]
    assert [(row["category_id"], row["available_minor"]) for row in after["categories"]] == [
        (row["category_id"], row["available_minor"]) for row in before["categories"]
    ]
    restored = client.patch(
        f"/api/v1/budgets/{budget['id']}/allowances/{plan['id']}/status",
        headers=auth(owner_token), json={"is_active": True},
    )
    assert restored.status_code == 200
    assert restored.json()["is_active"] is True
