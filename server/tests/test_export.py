import csv
from io import StringIO

from app.models import Household

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
