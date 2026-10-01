from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.encoders import jsonable_encoder
from sqlalchemy import func, inspect, select
from sqlalchemy.orm import Session

from .access import find_visible_budget, has_capability, is_household_owner, visible_resource_ids
from .config import Settings
from .database import get_db
from .dependencies import get_current_user
from .dependencies import get_settings
from .models import (
    Account,
    AccountDebtTerms,
    AllocationOperation,
    AllocationPosting,
    AllowanceIssuance,
    AllowancePlan,
    AllowanceSplit,
    BudgetGrant,
    BudgetAccessProfile,
    CashRolloverPolicyChange,
    CapabilityGrant,
    Category,
    CategoryFavorite,
    CategoryGroup,
    CategoryTarget,
    CategoryTargetSnooze,
    CreditCardReserveEvent,
    DelegatedBudgetPolicy,
    DelegatedCategoryRule,
    FinancialRequest,
    Household,
    HouseholdAccessEvent,
    ImportBatch,
    Invitation,
    MonthlyAssignment,
    Membership,
    Payee,
    PayeeAlias,
    PayeeBudgetPreference,
    RequestAction,
    ResourceGrant,
    ScheduledTransaction,
    Transaction,
    TransactionAttachment,
    TransactionChange,
    TransactionSplit,
    User,
)
from .portable_data import FORMAT_NAME, FORMAT_VERSION, section_manifest


router = APIRouter(prefix="/api/v1/budgets/{budget_id}")


def _sanitized_health(value: object, expected_states: set[str], include_prior: bool = True) -> dict | None:
    if not isinstance(value, dict) or value.get("state") not in expected_states:
        return None
    allowed = {
        "state", "archive", "completed_at", "sha256", "size", "destination", "error",
        "verified_at", "source_provider", "source_archive_sha256", "database_integrity",
        "foreign_keys",
    }
    result = {key: value[key] for key in allowed if key in value}
    if isinstance(result.get("destination"), dict):
        destination_allowed = {
            "destination", "path", "filename", "size", "sha256", "content_hash",
            "verified_at", "removed_generations",
        }
        result["destination"] = {
            key: result["destination"][key]
            for key in destination_allowed if key in result["destination"]
        }
    if include_prior and "last_successful" in value:
        prior = _sanitized_health(value["last_successful"], {"healthy"}, include_prior=False)
        if prior is not None:
            result["last_successful"] = prior
    return result


def _health_document(path_value: str | None, expected_states: set[str]) -> dict | None:
    if not path_value:
        return None
    configured = Path(path_value).expanduser()
    if configured.is_symlink():
        return {"state": "invalid", "message": "Backup health metadata is unreadable"}
    path = configured.resolve()
    if not path.exists():
        return None
    try:
        metadata = path.lstat()
        if not path.is_file() or metadata.st_size > 64 * 1024:
            raise ValueError
        value = json.loads(path.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return {"state": "invalid", "message": "Backup health metadata is unreadable"}
    result = _sanitized_health(value, expected_states)
    return result or {"state": "invalid", "message": "Backup health metadata is invalid"}


def _schedule_document(path_value: str | None) -> dict | None:
    """Read the owner-visible scheduler contract without exposing host configuration."""
    if not path_value:
        return None
    configured = Path(path_value).expanduser()
    if configured.is_symlink():
        return {"state": "invalid", "message": "Backup schedule metadata is unreadable"}
    path = configured.resolve()
    if not path.exists():
        return None
    try:
        metadata = path.lstat()
        if not path.is_file() or metadata.st_size > 16 * 1024:
            raise ValueError
        value = json.loads(path.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return {"state": "invalid", "message": "Backup schedule metadata is unreadable"}
    if not isinstance(value, dict) or value.get("state") not in {"enabled", "disabled"}:
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    allowed = {"state", "provider", "frequency", "hour", "minute", "retention", "updated_at"}
    result = {key: value[key] for key in allowed if key in value}
    if result.get("provider") not in {"launchd", "systemd", "windows_task", "qnap_cron"}:
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    if result.get("frequency") != "daily":
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    if type(result.get("hour")) is not int or not 0 <= result["hour"] <= 23:
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    if type(result.get("minute")) is not int or not 0 <= result["minute"] <= 59:
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    if "retention" in result and (type(result["retention"]) is not int or result["retention"] < 1):
        return {"state": "invalid", "message": "Backup schedule metadata is invalid"}
    return result


@router.get("/backup-status")
def owner_backup_status(
    budget_id: str,
    user: User = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=404, detail="Budget not found")
    backup = _health_document(settings.backup_status_path, {"healthy", "failed", "publication_failed"})
    schedule = _schedule_document(settings.backup_schedule_status_path)
    recovery = _health_document(settings.recovery_status_path, {"verified"})
    last_successful = None
    if backup is not None:
        if backup.get("state") == "healthy":
            last_successful = {key: value for key, value in backup.items() if key != "last_successful"}
        elif isinstance(backup.get("last_successful"), dict):
            last_successful = backup["last_successful"]
    return {
        "configured": bool(
            settings.backup_status_path
            or settings.backup_schedule_status_path
            or settings.recovery_status_path
        ),
        "backup": backup or {"state": "never"},
        "last_successful_backup": last_successful,
        "schedule": schedule,
        "last_restore_verification": recovery,
    }


def row_data(item) -> dict:
    return {
        attribute.key: getattr(item, attribute.key)
        for attribute in inspect(item).mapper.column_attrs
    }


@router.get("/local-device-transfer-eligibility")
def local_device_transfer_eligibility(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Describe whether a server budget can move to the single-user phone authority losslessly.

    This is intentionally stricter than ordinary export. Local Device must never silently flatten
    household authorization or discard audit history merely because the financial snapshot fits.
    """
    budget = find_visible_budget(db, user, budget_id)
    if budget is None or not is_household_owner(db, user, budget.household_id):
        raise HTTPException(status_code=404, detail="Budget not found")
    household = db.get(Household, budget.household_id)
    if household is None:
        raise HTTPException(status_code=404, detail="Budget not found")

    blockers: list[dict[str, object]] = []

    def add(code: str, title: str, count: int) -> None:
        if count > 0:
            blockers.append({"code": code, "title": title, "record_count": count})

    def count(model, *criteria) -> int:
        return int(db.scalar(select(func.count()).select_from(model).where(*criteria)) or 0)

    add(
        "shared_household_history",
        "This household contains another member's identity or access history.",
        count(Membership, Membership.household_id == household.id, Membership.user_id != household.owner_user_id)
        + count(Invitation, Invitation.household_id == household.id)
        + count(HouseholdAccessEvent, HouseholdAccessEvent.household_id == household.id),
    )
    add(
        "delegation_and_requests",
        "Delegated budgets, requests, or allowances require Budget Server.",
        count(DelegatedBudgetPolicy, DelegatedBudgetPolicy.budget_id == budget.id)
        + count(FinancialRequest, FinancialRequest.budget_id == budget.id)
        + count(AllowancePlan, AllowancePlan.budget_id == budget.id)
        + count(AllowanceIssuance, AllowanceIssuance.budget_id == budget.id),
    )
    add(
        "authorization_policy",
        "Budget access grants cannot be represented by single-user Local Device mode.",
        count(BudgetGrant, BudgetGrant.budget_id == budget.id, BudgetGrant.user_id != household.owner_user_id)
        + count(BudgetAccessProfile, BudgetAccessProfile.budget_id == budget.id)
        + count(CapabilityGrant, CapabilityGrant.budget_id == budget.id)
        + count(ResourceGrant, ResourceGrant.budget_id == budget.id),
    )
    add(
        "unsupported_audit_history",
        "This budget has server audit or import history not yet represented on Local Device.",
        count(ImportBatch, ImportBatch.budget_id == budget.id)
        + count(MonthlyAssignment, MonthlyAssignment.budget_id == budget.id),
    )
    add(
        "non_owner_financial_attribution",
        "Financial records attributed to another household member cannot be flattened to one owner.",
        count(Transaction, Transaction.budget_id == budget.id, Transaction.created_by_user_id != household.owner_user_id)
        + count(AllocationOperation, AllocationOperation.budget_id == budget.id, AllocationOperation.actor_user_id != household.owner_user_id)
        + count(TransactionChange, TransactionChange.budget_id == budget.id, TransactionChange.actor_user_id != household.owner_user_id)
        + count(CreditCardReserveEvent, CreditCardReserveEvent.budget_id == budget.id, CreditCardReserveEvent.actor_user_id != household.owner_user_id),
    )

    return {
        "target_provider": "local_device",
        "eligible": not blockers,
        "budget_id": budget.id,
        "budget_name": budget.name,
        "blockers": blockers,
        "source_unchanged": True,
        "requires_new_local_authority": True,
    }


@router.get("/export.json")
def export_budget_json(
    budget_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    budget = find_visible_budget(db, user, budget_id)
    if budget is None:
        raise HTTPException(status_code=404, detail="Budget not found")
    if not has_capability(db, user, budget, "export_data"):
        raise HTTPException(status_code=403, detail="Insufficient capability")
    # This artifact contains whole-budget data and household administration records. The
    # ordinary export capability must not override an explicit resource restriction. Scoped
    # users can export authorized transaction/report rows through the existing CSV paths.
    if any(visible_resource_ids(db, user, budget, resource) is not None for resource in ("account", "category")):
        raise HTTPException(status_code=403, detail="Full structured export requires unrestricted resource access")

    operations = list(db.scalars(select(AllocationOperation).where(
        AllocationOperation.budget_id == budget_id
    )))
    operation_ids = [item.id for item in operations]
    transactions = list(db.scalars(select(Transaction).where(Transaction.budget_id == budget_id)))
    transaction_ids = [item.id for item in transactions]
    requests = list(db.scalars(select(FinancialRequest).where(FinancialRequest.budget_id == budget_id)))
    request_ids = [item.id for item in requests]
    plans = list(db.scalars(select(AllowancePlan).where(AllowancePlan.budget_id == budget_id)))
    plan_ids = [item.id for item in plans]
    targets = list(db.scalars(select(CategoryTarget).where(CategoryTarget.budget_id == budget_id)))
    target_ids = [item.id for item in targets]
    policies = list(db.scalars(select(DelegatedBudgetPolicy).where(
        DelegatedBudgetPolicy.budget_id == budget_id
    )))
    policy_ids = [item.id for item in policies]
    payee_preferences = list(db.scalars(select(PayeeBudgetPreference).where(
        PayeeBudgetPreference.budget_id == budget_id
    )))
    # Payees are household-scoped first-class identities. Preserve the full household directory,
    # including archived/unreferenced identities and aliases, so a move does not silently discard
    # rename/merge history merely because this budget has not used a payee recently.
    payees = list(db.scalars(select(Payee).where(Payee.household_id == budget.household_id)))
    payee_ids = {item.id for item in payees}

    sections = {
        # Version 2 is the first completeness-audited contract. It remains a JSON data export;
        # attachment ciphertext is carried by the encrypted operational backup until the portable
        # archive container/importer is introduced.
        "budget": row_data(budget),
        "household": row_data(db.get(Household, budget.household_id)),
        "household_members": [row_data(item) for item in db.scalars(select(Membership).where(
            Membership.household_id == budget.household_id
        ))],
        "household_invitations": [{key: value for key, value in row_data(item).items() if key != "token_hash"} for item in db.scalars(select(Invitation).where(
            Invitation.household_id == budget.household_id
        ))],
        "household_access_events": [row_data(item) for item in db.scalars(select(HouseholdAccessEvent).where(
            HouseholdAccessEvent.household_id == budget.household_id
        ))],
        "user_directory": [{
            "id": item.id,
            "email": item.email,
            "display_name": item.display_name,
            "created_at": item.created_at,
        } for item in db.scalars(select(User).where(User.id.in_(select(Membership.user_id).where(
            Membership.household_id == budget.household_id
        ))))],
        "accounts": [row_data(item) for item in db.scalars(select(Account).where(Account.budget_id == budget_id))],
        "account_debt_terms": [row_data(item) for item in db.scalars(select(AccountDebtTerms).where(AccountDebtTerms.budget_id == budget_id))],
        "cash_rollover_policy_changes": [row_data(item) for item in db.scalars(select(CashRolloverPolicyChange).where(CashRolloverPolicyChange.budget_id == budget_id))],
        "category_groups": [row_data(item) for item in db.scalars(select(CategoryGroup).where(CategoryGroup.budget_id == budget_id))],
        "categories": [row_data(item) for item in db.scalars(select(Category).where(Category.budget_id == budget_id))],
        "category_favorites": [row_data(item) for item in db.scalars(select(CategoryFavorite).where(CategoryFavorite.budget_id == budget_id))],
        "delegated_budget_policies": [row_data(item) for item in policies],
        "delegated_category_rules": [row_data(item) for item in db.scalars(select(DelegatedCategoryRule).where(
            DelegatedCategoryRule.policy_id.in_(policy_ids)
        ))] if policy_ids else [],
        "targets": [row_data(item) for item in targets],
        "target_snoozes": [row_data(item) for item in db.scalars(select(CategoryTargetSnooze).where(
            CategoryTargetSnooze.target_id.in_(target_ids)
        ))] if target_ids else [],
        "scheduled_transactions": [row_data(item) for item in db.scalars(select(ScheduledTransaction).where(ScheduledTransaction.budget_id == budget_id))],
        "payees": [row_data(item) for item in payees],
        "payee_aliases": [row_data(item) for item in db.scalars(select(PayeeAlias).where(
            PayeeAlias.payee_id.in_(payee_ids)
        ))] if payee_ids else [],
        "payee_budget_preferences": [row_data(item) for item in payee_preferences],
        "transactions": [row_data(item) for item in transactions],
        "transaction_splits": [row_data(item) for item in db.scalars(select(TransactionSplit).where(
            TransactionSplit.transaction_id.in_(transaction_ids)
        ))] if transaction_ids else [],
        "transaction_changes": [row_data(item) for item in db.scalars(select(TransactionChange).where(
            TransactionChange.budget_id == budget_id
        ))],
        # storage_key is a provider implementation detail. Portable archives address decrypted,
        # integrity-checked payloads by stable attachment ID instead.
        "transaction_attachments": [
            {key: value for key, value in row_data(item).items() if key != "storage_key"}
            for item in db.scalars(select(TransactionAttachment).where(
                TransactionAttachment.budget_id == budget_id
            ))
        ],
        "import_batches": [row_data(item) for item in db.scalars(select(ImportBatch).where(
            ImportBatch.budget_id == budget_id
        ))],
        "allocation_operations": [row_data(item) for item in operations],
        "allocation_postings": [row_data(item) for item in db.scalars(select(AllocationPosting).where(
            AllocationPosting.operation_id.in_(operation_ids)
        ))] if operation_ids else [],
        "credit_card_reserve_events": [row_data(item) for item in db.scalars(select(CreditCardReserveEvent).where(
            CreditCardReserveEvent.budget_id == budget_id
        ))],
        "requests": [row_data(item) for item in requests],
        "request_actions": [row_data(item) for item in db.scalars(select(RequestAction).where(
            RequestAction.request_id.in_(request_ids)
        ))] if request_ids else [],
        "allowance_plans": [row_data(item) for item in plans],
        "allowance_splits": [row_data(item) for item in db.scalars(select(AllowanceSplit).where(
            AllowanceSplit.plan_id.in_(plan_ids)
        ))] if plan_ids else [],
        "allowance_issuances": [row_data(item) for item in db.scalars(select(AllowanceIssuance).where(
            AllowanceIssuance.budget_id == budget_id
        ))],
        "legacy_monthly_assignments": [row_data(item) for item in db.scalars(select(MonthlyAssignment).where(
            MonthlyAssignment.budget_id == budget_id
        ))],
        "budget_grants": [row_data(item) for item in db.scalars(select(BudgetGrant).where(
            BudgetGrant.budget_id == budget_id
        ))],
        "access_profiles": [row_data(item) for item in db.scalars(select(BudgetAccessProfile).where(
            BudgetAccessProfile.budget_id == budget_id
        ))],
        "capability_grants": [row_data(item) for item in db.scalars(select(CapabilityGrant).where(
            CapabilityGrant.budget_id == budget_id
        ))],
        "resource_grants": [row_data(item) for item in db.scalars(select(ResourceGrant).where(
            ResourceGrant.budget_id == budget_id
        ))],
    }
    payload = {
        "format": FORMAT_NAME,
        "schema_version": FORMAT_VERSION,
        "exported_at": datetime.now(timezone.utc),
        "attachment_payloads_included": False,
        "section_manifest": section_manifest(sections),
        # Keep data sections top-level for backward compatibility with the v1 audit export.
        **sections,
    }
    return jsonable_encoder(payload)
