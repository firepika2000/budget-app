import csv
from io import StringIO
import pytest

from app.models import Household
from .test_delegated_access import add_child

from .conftest import auth


@pytest.mark.parametrize("restrict_accounts,restrict_categories", [(False, False), (True, False), (False, True), (True, True)])
def test_household_structured_export_cannot_override_resource_restrictions(
    client, owner_token, session_factory, restrict_accounts, restrict_categories
):
    from .test_budgeting_api import create_budget, create_budget_structure
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    child_id, child_token = add_child(session_factory, client)
    path = f"/api/v1/budgets/{budget['id']}"
    assert client.put(f"{path}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "manage",
    }).status_code == 200
    assert client.put(f"{path}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_reports", "export_data"],
        "restrict_accounts": restrict_accounts, "account_ids": [account["id"]] if restrict_accounts else [],
        "restrict_categories": restrict_categories, "category_ids": [category["id"]] if restrict_categories else [],
    }).status_code == 200
    response = client.get(f"{path}/export.json", headers=auth(child_token))
    restricted = restrict_accounts or restrict_categories
    assert response.status_code == (403 if restricted else 200)
    if restricted:
        assert "household_members" not in response.text
    assert client.get(f"{path}/export.csv", headers=auth(child_token)).status_code == 200
    assert client.get(f"{path}/export.json", headers=auth(owner_token)).status_code == 200


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
    assert data["schema_version"] == 2
    assert data["format"] == "budget-app-portable-data"
    assert data["attachment_payloads_included"] is False
    sections = {
        key: value for key, value in data.items()
        if key not in {"format", "schema_version", "exported_at", "attachment_payloads_included", "section_manifest"}
    }
    assert sections["budget"]["id"] == budget["id"]
    assert sections["accounts"][0]["id"] == account["id"]
    assert sections["transactions"][0]["amount_minor"] == 5000
    assert len(sections["allocation_operations"]) == 1
    assert sum(item["amount_minor"] for item in sections["allocation_postings"]) == 0
    from app.portable_data import validate_section_manifest
    validate_section_manifest(sections, data["section_manifest"])
    assert "password_hash" not in exported.text
    assert "token_hash" not in exported.text

    child_id, child_token = add_child(session_factory, client)
    client.put(f"{path}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "contribute",
    })
    assert client.get(f"{path}/export.json", headers=auth(child_token)).status_code == 403


def test_structured_export_contract_covers_every_persistent_domain_model():
    """A new persistence model must be deliberately exported or deliberately excluded."""
    from app.database import Base

    exported_tables = {
        "households", "memberships", "invitations", "household_access_events", "users",
        "budgets", "cash_rollover_policy_changes", "payees", "payee_aliases",
        "payee_budget_preferences", "budget_grants", "budget_access_profiles",
        "capability_grants", "resource_grants", "accounts", "account_debt_terms",
        "category_groups", "categories", "category_favorites", "delegated_budget_policies",
        "delegated_category_rules", "category_targets", "category_target_snoozes",
        "scheduled_transactions", "monthly_assignments", "allocation_operations",
        "allocation_postings", "transactions", "transaction_splits", "transaction_changes",
        "transaction_attachments", "credit_card_reserve_events", "allowance_plans",
        "allowance_splits", "allowance_issuances", "financial_requests", "request_actions",
        "import_batches",
    }
    deliberately_deployment_local = {"setup_state", "refresh_sessions"}

    assert set(Base.metadata.tables) == exported_tables | deliberately_deployment_local


def test_portable_data_manifest_rejects_tampering():
    from app.portable_data import section_manifest, validate_section_manifest

    sections = {"transactions": [{"id": "transaction-1", "amount_minor": -123}]}
    manifest = section_manifest(sections)
    validate_section_manifest(sections, manifest)

    sections["transactions"][0]["amount_minor"] = -124
    with pytest.raises(ValueError, match="transactions"):
        validate_section_manifest(sections, manifest)
