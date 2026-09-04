import csv
from io import StringIO

from app.models import Household
from .test_delegated_access import add_child

from .conftest import auth


def test_csv_export_is_permission_scoped_and_formula_safe(
    client, owner_token, session_factory
):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    budget = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id,
        "name": "Family",
        "currency_code": "USD",
    }).json()
    budget_path = f"/api/v1/budgets/{budget['id']}"
    account = client.post(f"{budget_path}/accounts", headers=auth(owner_token), json={
        "name": "=FORMULA",
        "account_type": "checking",
        "is_on_budget": True,
    }).json()
    group = client.post(f"{budget_path}/category-groups", headers=auth(owner_token), json={
        "name": "Living",
    }).json()
    category = client.post(f"{budget_path}/categories", headers=auth(owner_token), json={
        "group_id": group["id"],
        "name": "Groceries",
    }).json()
    created = client.post(f"{budget_path}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"],
        "category_id": category["id"],
        "amount_minor": -4250,
        "occurred_on": "2026-09-04",
        "payee_name": "+Suspicious payee",
        "memo": "weekly food",
    })
    assert created.status_code == 201

    response = client.get(f"{budget_path}/export.csv", headers=auth(owner_token))

    assert response.status_code == 200
    assert response.headers["content-disposition"] == 'attachment; filename="budget-export.csv"'
    rows = list(csv.DictReader(StringIO(response.text.lstrip("\ufeff"))))
    assert len(rows) == 1
    assert rows[0]["account"] == "'=FORMULA"
    assert rows[0]["payee"] == "'+Suspicious payee"
    assert rows[0]["amount_minor"] == "-4250"
    assert rows[0]["currency"] == "USD"


def test_unknown_budget_export_does_not_disclose_existence(client, owner_token):
    response = client.get(
        "/api/v1/budgets/not-visible/export.csv",
        headers=auth(owner_token),
    )
    assert response.status_code == 404


def test_structured_export_contains_reconstructable_audit_data_and_requires_capability(
    client, owner_token, session_factory
):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    budget = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id,
        "name": "Portable",
        "currency_code": "USD",
    }).json()
    path = f"/api/v1/budgets/{budget['id']}"
    account = client.post(f"{path}/accounts", headers=auth(owner_token), json={
        "name": "Checking", "account_type": "checking",
    }).json()
    group = client.post(f"{path}/category-groups", headers=auth(owner_token), json={
        "name": "Living",
    }).json()
    category = client.post(f"{path}/categories", headers=auth(owner_token), json={
        "group_id": group["id"], "name": "Groceries",
    }).json()
    client.post(f"{path}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "amount_minor": 5000,
        "occurred_on": "2026-09-04", "is_cleared": True,
    })
    client.put(
        f"{path}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 2000},
    )

    exported = client.get(f"{path}/export.json", headers=auth(owner_token))
    assert exported.status_code == 200, exported.text
    data = exported.json()
    assert data["schema_version"] == 1
    assert data["budget"]["id"] == budget["id"]
    assert data["accounts"][0]["id"] == account["id"]
    assert data["transactions"][0]["amount_minor"] == 5000
    assert len(data["allocation_operations"]) == 1
    assert sum(item["amount_minor"] for item in data["allocation_postings"]) == 0
    assert "password_hash" not in exported.text

    child_id, child_token = add_child(session_factory, client)
    client.put(f"{path}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "contribute",
    })
    assert client.get(f"{path}/export.json", headers=auth(child_token)).status_code == 403
