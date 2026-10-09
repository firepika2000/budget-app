import csv
from dataclasses import replace
from datetime import date
from io import StringIO
import json
import pytest

from app.models import DebtPayoffPlan, Household, MonthlyAssignment, Payee, TransactionSplit
from app.local_device_export import source_revision
from .test_delegated_access import add_child

from .conftest import auth


def test_local_device_source_revision_excludes_response_time_but_covers_authority_content():
    first = {"generated_at": "2026-10-01T12:00:00Z", "identity": {"budget_id": "one"}}
    second = {"generated_at": "2026-10-01T12:01:00Z", "identity": {"budget_id": "one"}}
    assert source_revision(first) == source_revision(second)
    second["identity"]["budget_id"] = "two"
    assert source_revision(first) != source_revision(second)


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


def test_local_device_transfer_eligibility_is_owner_only_and_refuses_shared_history(
    client, owner_token, session_factory
):
    from .test_advanced_ledger import record
    from .test_budgeting_api import create_budget, create_budget_structure

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=category["id"], amount_minor=-500, occurred_on="2026-10-01",
    )
    path = f"/api/v1/budgets/{budget['id']}/local-device-transfer-eligibility"

    personal = client.get(path, headers=auth(owner_token))
    assert personal.status_code == 200, personal.text
    assert personal.json() == {
        "target_provider": "local_device",
        "eligible": True,
        "budget_id": budget["id"],
        "budget_name": budget["name"],
        "blockers": [],
        "source_unchanged": True,
        "requires_new_local_authority": True,
    }

    child_id, child_token = add_child(session_factory, client)
    client.put(
        f"/api/v1/budgets/{budget['id']}/grants",
        headers=auth(owner_token),
        json={"user_id": child_id, "permission": "view"},
    )
    shared = client.get(path, headers=auth(owner_token))
    assert shared.status_code == 200
    assert shared.json()["eligible"] is False
    assert {item["code"] for item in shared.json()["blockers"]} >= {
        "shared_household_history", "authorization_policy"
    }
    # Eligibility itself is sensitive household administration metadata.
    assert client.get(path, headers=auth(child_token)).status_code == 404
    assert client.get(
        "/api/v1/budgets/not-visible/local-device-transfer-eligibility",
        headers=auth(owner_token),
    ).status_code == 404


def test_local_device_transfer_projects_exact_ledgers_and_attachment_manifest(
    client, owner_token, session_factory
):
    from .test_advanced_ledger import record
    from .test_budgeting_api import create_budget, create_budget_structure

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}"
    category_update = client.put(
        f"{path}/categories/{category['id']}", headers=auth(owner_token), json={
            "group_id": category["group_id"], "name": category["name"],
            "icon_name": "cart.fill", "note": "Keep a weekly grocery buffer",
            "sort_order": category["sort_order"], "is_archived": False,
            "is_essential": True, "is_emergency_fund": False,
        },
    )
    assert category_update.status_code == 200, category_update.text
    income = record(
        client, owner_token, budget["id"], account_id=account["id"],
        amount_minor=10_000, occurred_on="2026-09-01", payee_name="Payroll",
        is_cleared=True,
    )
    assignment = client.put(
        f"{path}/categories/{category['id']}/assignment", headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 4_000},
    )
    assert assignment.status_code == 200, assignment.text
    # Migration 0006 retains this pre-ledger row for historical compatibility after
    # converting it to the canonical balanced allocation operation above. It must not
    # strand an otherwise personal budget or be projected a second time.
    with session_factory() as db:
        db.add(MonthlyAssignment(
            budget_id=budget["id"], category_id=category["id"],
            month=date(2026, 9, 1), assigned_minor=4_000,
        ))
        db.commit()
    purchase = record(
        client, owner_token, budget["id"], account_id=account["id"],
        amount_minor=-1_250, splits=[{
            "category_id": category["id"], "amount_minor": -1_250,
        }],
        occurred_on="2026-09-02", payee_name="Market", memo="groceries",
    )
    # Classification was validly recorded by an older server/account configuration. Transfer must
    # preserve stored semantics rather than reinterpret them through today's command validation.
    with session_factory() as db:
        split = db.query(TransactionSplit).filter_by(transaction_id=purchase["id"]).one()
        split.financial_classification = "interest_charge"
        db.commit()
    receipt = b"%PDF-1.4\nlocal-device-transfer-receipt\n%%EOF"
    uploaded = client.post(
        f"{path}/transactions/{purchase['id']}/attachments",
        headers={**auth(owner_token), "X-Attachment-Filename": "receipt.pdf",
                 "X-Attachment-Content-Type": "application/pdf",
                 "Content-Type": "application/octet-stream"},
        content=receipt,
    )
    assert uploaded.status_code == 201, uploaded.text
    staged = client.post(
        f"{path}/accounts/{account['id']}/statement-imports",
        headers={
            **auth(owner_token), "Content-Type": "application/octet-stream",
            "X-Statement-Format": "csv", "X-Statement-Currency": "USD",
            "X-CSV-Date-Column": "Date", "X-CSV-Amount-Column": "Amount",
            "X-CSV-Payee-Column": "Payee", "X-CSV-Memo-Column": "Memo",
            "X-Statement-Date-Order": "ymd",
        },
        content=b"Date,Amount,Payee,Memo\n2026-09-03,-2.50,Portable import,Retain review\n",
    )
    assert staged.status_code == 201, staged.text
    schedule = client.post(
        f"{path}/scheduled-transactions", headers=auth(owner_token), json={
            "account_id": account["id"], "category_id": category["id"],
            "name": "Scheduled groceries", "amount_minor": -500,
            "next_date": "2026-09-04", "recurrence_unit": "months",
        },
    )
    assert schedule.status_code == 201, schedule.text
    realized = client.post(
        f"{path}/scheduled-transactions/{schedule.json()['id']}/realize",
        headers=auth(owner_token),
    )
    assert realized.status_code == 200, realized.text
    with session_factory() as db:
        owner_id = db.query(Household.owner_user_id).scalar()
        db.add(DebtPayoffPlan(
            budget_id=budget["id"], user_id=owner_id, strategy="snowball",
            rollover=True, extra_payment_minor=12_345, account_ids=[], custom_order=[],
            target_date=date(2028, 12, 31),
        ))
        db.commit()
    eligibility = client.get(f"{path}/local-device-transfer-eligibility", headers=auth(owner_token))
    assert eligibility.status_code == 200 and eligibility.json()["eligible"] is True

    response = client.get(f"{path}/local-device-transfer", headers=auth(owner_token))

    assert response.status_code == 200, response.text
    value = response.json()
    assert value["format"] == "com.clearpocket.local-device-transfer"
    assert value["version"] == 1
    assert len(value["source_revision"]) == 64
    assert value["identity"]["budget_id"] == budget["id"]
    assert value["accounts"][0]["opening_balance_minor"] == 0
    exported_category = next(item for item in value["categories"] if item["id"] == category["id"])
    assert exported_category["icon_name"] == "cart.fill"
    assert exported_category["note"] == "Keep a weekly grocery buffer"
    assert exported_category["is_essential"] is True
    assert exported_category["is_emergency_fund"] is False
    transactions = {item["id"]: item for item in value["transactions"]}
    assert transactions[income["id"]]["splits"] == []
    assert transactions[purchase["id"]]["splits"][0]["category_id"] == category["id"]
    assert transactions[purchase["id"]]["splits"][0]["amount_minor"] == -1_250
    assert transactions[purchase["id"]]["splits"][0]["financial_classification"] == "interest_charge"
    realized_transaction_id = realized.json()["transaction_ids"][0]
    assert transactions[realized_transaction_id]["scheduled_transaction_id"] == schedule.json()["id"]
    exported_schedule = next(item for item in value["schedules"] if item["id"] == schedule.json()["id"])
    assert exported_schedule["last_realized_on"] == "2026-09-04"
    assert value["allocations"][0]["category_id"] == category["id"]
    assert value["allocations"][0]["source_category_id"] is None
    assert value["allocations"][0]["amount_minor"] == 4_000
    assert value["debt_payoff_plans"] == [{
        **{key: value["debt_payoff_plans"][0][key] for key in ("id", "updated_at")},
        "budget_id": budget["id"], "user_id": value["identity"]["owner_user_id"],
        "strategy": "snowball", "rollover": True, "extra_payment_minor": 12_345,
        "account_ids": [], "custom_order": [], "target_date": "2028-12-31",
    }]
    assert value["attachments"] == [{
        "id": uploaded.json()["id"], "transaction_id": purchase["id"],
        "filename": "receipt.pdf", "content_type": "application/pdf",
        "size_bytes": len(receipt), "sha256": uploaded.json()["sha256"],
        "object_name": uploaded.json()["id"], "created_at": uploaded.json()["created_at"],
    }]
    staged_created_at = staged.json()["created_at"].removesuffix("Z")
    assert len(value["statement_imports"]) == 1
    imported = value["statement_imports"][0]
    assert imported == {
        **{key: imported[key] for key in ("payload",)},
        "id": staged.json()["id"], "budget_id": budget["id"], "account_id": account["id"],
        "status": "review", "version": 1, "source_format": "csv", "candidate_count": 1,
        "created_at": staged_created_at,
    }
    assert imported["payload"] == {
        **{key: imported["payload"][key] for key in ("candidates",)},
        **{key: staged.json()[key] for key in (
            "id", "budget_id", "account_id", "status", "source_format", "candidate_count",
        )},
        "version": 1, "created_at": staged_created_at,
    }
    candidate = imported["payload"]["candidates"][0]
    assert candidate["source_row"] == 2
    assert candidate["occurred_on"] == "2026-09-03"
    assert candidate["amount_minor"] == -250
    assert candidate["payee"] == "Portable import"
    assert candidate["memo"] == "Retain review"
    assert candidate["exact_transaction_ids"] == []
    assert candidate["possible_transaction_ids"] == []
    assert candidate["suggestions_truncated"] is False
    assert candidate["duplicate_source_row"] is False
    observations = value["observations"]
    assert observations["transaction_count"] == 3
    assert observations["transactions"] == [{
        "account_id": account["id"], "status": "posted", "amount_minor": 8_250,
    }]
    assert observations["allocation_count"] == 2
    assert sum(item["amount_minor"] for item in observations["allocations"]) == 0
    assert observations["reserve_count"] == 0
    repeated = client.get(f"{path}/local-device-transfer", headers=auth(owner_token))
    assert repeated.status_code == 200
    assert repeated.json()["source_revision"] == value["source_revision"]


def test_local_device_transfer_preserves_merged_payee_redirect_history(
    client, owner_token, session_factory
):
    from .test_budgeting_api import create_budget

    budget = create_budget(client, owner_token, session_factory)
    path = f"/api/v1/budgets/{budget['id']}"
    source = client.post(f"{path}/payees", headers=auth(owner_token), json={
        "display_name": "Old Market",
    })
    destination = client.post(f"{path}/payees", headers=auth(owner_token), json={
        "display_name": "Market",
    })
    assert source.status_code == destination.status_code == 201
    merged = client.post(
        f"{path}/payees/{source.json()['id']}/merge", headers=auth(owner_token),
        json={"destination_payee_id": destination.json()["id"]},
    )
    assert merged.status_code == 200, merged.text

    eligibility = client.get(f"{path}/local-device-transfer-eligibility", headers=auth(owner_token))
    assert eligibility.status_code == 200
    assert eligibility.json()["eligible"] is True
    response = client.get(f"{path}/local-device-transfer", headers=auth(owner_token))
    assert response.status_code == 200, response.text
    payees = {item["id"]: item for item in response.json()["payees"]}
    assert payees[source.json()["id"]]["is_archived"] is True
    assert payees[source.json()["id"]]["merged_into_payee_id"] == destination.json()["id"]


def test_local_device_transfer_preserves_detached_history_and_rejects_non_owner(
    client, owner_token, session_factory
):
    from .test_advanced_ledger import record
    from .test_budgeting_api import create_budget, create_budget_structure

    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=category["id"], amount_minor=-500, occurred_on="2026-09-01",
    )
    path = f"/api/v1/budgets/{budget['id']}"
    uploaded = client.post(
        f"{path}/transactions/{transaction['id']}/attachments",
        headers={**auth(owner_token), "X-Attachment-Filename": "receipt.pdf",
                 "X-Attachment-Content-Type": "application/pdf",
                 "Content-Type": "application/octet-stream"},
        content=b"%PDF-1.4\nreceipt\n%%EOF",
    ).json()
    assert client.delete(
        f"{path}/transactions/{transaction['id']}/attachments/{uploaded['id']}",
        headers=auth(owner_token),
    ).status_code == 204

    eligibility = client.get(
        f"{path}/local-device-transfer-eligibility", headers=auth(owner_token)
    ).json()
    assert eligibility["eligible"] is True
    transferred = client.get(f"{path}/local-device-transfer", headers=auth(owner_token))
    assert transferred.status_code == 200, transferred.text
    assert transferred.json()["attachments"] == []
    tombstone = transferred.json()["attachment_tombstones"][0]
    assert tombstone["id"] == uploaded["id"]
    assert tombstone["transaction_id"] == transaction["id"]
    assert tombstone["sha256"] == uploaded["sha256"]
    assert tombstone["detached_at"] is not None
    assert tombstone["detached_by_user_id"] is not None
    assert tombstone["purge_after"] is not None
    assert tombstone["tombstone_object_name"] is None

    child_id, child_token = add_child(session_factory, client)
    client.put(
        f"{path}/grants", headers=auth(owner_token),
        json={"user_id": child_id, "permission": "view"},
    )
    assert client.get(f"{path}/local-device-transfer", headers=auth(child_token)).status_code == 404


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
        "occurred_on": "2026-09-04", "is_cleared": True, "payee_name": "Payroll",
    })
    with session_factory() as db:
        household = db.get(Household, household_id)
        db.add(Payee(
            household_id=household_id, display_name="Archived historical payee",
            name_key="archived historical payee", is_archived=True,
            created_by_user_id=household.owner_user_id,
        ))
        db.commit()
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
    payees_by_name = {item["display_name"]: item for item in sections["payees"]}
    assert payees_by_name["Archived historical payee"]["is_archived"] is True
    assert sections["transactions"][0]["payee_id"] == payees_by_name["Payroll"]["id"]
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
        "budgets", "budget_structure_revisions", "cash_rollover_policy_changes", "payees", "payee_aliases",
        "payee_budget_preferences", "payee_revisions", "budget_grants", "budget_access_profiles",
        "capability_grants", "resource_grants", "accounts", "account_revisions", "account_debt_terms",
        "account_debt_terms_revisions",
        "category_groups", "categories", "category_favorites", "delegated_budget_policies",
            "delegated_category_rules", "delegated_budget_policy_revisions", "category_targets", "category_target_snoozes",
            "category_target_revisions", "scheduled_transactions", "scheduled_transaction_revisions",
            "monthly_assignments", "allocation_operations",
            "allocation_postings", "transactions", "transaction_splits", "transaction_changes",
            "transaction_attachments", "reconciliations", "credit_card_reserve_events", "allowance_plans",
        "allowance_splits", "allowance_issuances", "allowance_plan_revisions", "financial_requests", "request_actions",
        "import_batches", "debt_payoff_plans",
    }
    deliberately_deployment_local = {"setup_state", "refresh_sessions", "pairing_codes"}

    assert set(Base.metadata.tables) == exported_tables | deliberately_deployment_local


def test_portable_data_manifest_rejects_tampering():
    from app.portable_data import section_manifest, validate_section_manifest

    sections = {"transactions": [{"id": "transaction-1", "amount_minor": -123}]}
    manifest = section_manifest(sections)
    validate_section_manifest(sections, manifest)

    sections["transactions"][0]["amount_minor"] = -124
    with pytest.raises(ValueError, match="transactions"):
        validate_section_manifest(sections, manifest)


def test_backup_health_is_owner_only_bounded_and_sanitized(
    client, owner_token, session_factory, tmp_path
):
    from .test_budgeting_api import create_budget
    budget = create_budget(client, owner_token, session_factory)
    backup = tmp_path / "backup-status.json"
    schedule = tmp_path / "backup-schedule.json"
    recovery = tmp_path / "recovery-status.json"
    backup.write_text(json.dumps({
        "state": "healthy", "archive": "/private/backup.age", "completed_at": "2026-09-27T12:00:00Z",
        "sha256": "a" * 64, "size": 123,
        "destination": {"destination": "dropbox", "path": "/Backups/backup.age", "secret": "must-not-leak"},
        "unexpected": "must-not-leak",
    }))
    recovery.write_text(json.dumps({
        "state": "verified", "verified_at": "2026-09-27T13:00:00Z",
        "source_provider": "portable_archive", "source_archive_sha256": "b" * 64,
        "database_integrity": "ok", "foreign_keys": "ok",
    }))
    schedule.write_text(json.dumps({
        "state": "enabled", "provider": "systemd", "frequency": "daily",
        "hour": 3, "minute": 15, "retention": 12,
        "updated_at": "2026-09-27T11:00:00Z", "command": "must-not-leak",
    }))
    client.app.state.settings = replace(
        client.app.state.settings,
        backup_status_path=str(backup), backup_schedule_status_path=str(schedule),
        recovery_status_path=str(recovery),
    )
    path = f"/api/v1/budgets/{budget['id']}/backup-status"

    response = client.get(path, headers=auth(owner_token))

    assert response.status_code == 200
    assert response.json()["backup"]["state"] == "healthy"
    assert response.json()["backup"]["destination"]["destination"] == "dropbox"
    assert response.json()["schedule"] == {
        "state": "enabled", "provider": "systemd", "frequency": "daily",
        "hour": 3, "minute": 15, "retention": 12,
        "updated_at": "2026-09-27T11:00:00Z",
    }
    assert response.json()["last_restore_verification"]["source_provider"] == "portable_archive"
    assert "must-not-leak" not in response.text

    schedule.write_text(json.dumps({
        "state": "enabled", "provider": "systemd", "frequency": "daily",
        "hour": 99, "minute": 0,
    }))
    invalid_schedule = client.get(path, headers=auth(owner_token))
    assert invalid_schedule.status_code == 200
    assert invalid_schedule.json()["schedule"]["state"] == "invalid"

    backup.write_text(json.dumps({
        "state": "failed", "completed_at": "2026-09-27T14:00:00Z",
        "error": "Backup capture failed", "private_detail": "must-not-leak",
        "last_successful": {
            "state": "healthy", "completed_at": "2026-09-27T12:00:00Z",
            "archive": "/private/backup.age", "sha256": "a" * 64, "size": 123,
            "destination": {"destination": "local_generation", "path": "/private/backup.age"},
            "credential": "must-not-leak",
        },
    }))
    failed = client.get(path, headers=auth(owner_token))
    assert failed.status_code == 200
    assert failed.json()["backup"]["state"] == "failed"
    assert failed.json()["backup"]["completed_at"] == "2026-09-27T14:00:00Z"
    assert failed.json()["backup"]["error"] == "Backup capture failed"
    assert failed.json()["last_successful_backup"]["completed_at"] == "2026-09-27T12:00:00Z"
    assert failed.json()["last_successful_backup"]["destination"]["destination"] == "local_generation"
    assert "must-not-leak" not in failed.text
    assert {key: failed.json()["backup"][key] for key in ("state", "completed_at", "error")} == {
        "state": "failed", "completed_at": "2026-09-27T14:00:00Z",
        "error": "Backup capture failed",
    }

    child_id, child_token = add_child(session_factory, client)
    assert client.put(f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "manage",
    }).status_code == 200
    denied = client.get(path, headers=auth(child_token))
    assert denied.status_code == 404
    assert "backup" not in denied.text.lower()
