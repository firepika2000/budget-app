"""Convert a verified iPhone Local Device authority into the canonical server payload."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sqlite3
from typing import Any
from uuid import NAMESPACE_URL, uuid5

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.category_names import normalized_category_name
from scripts.local_device_transfer import LocalDeviceTransferError, LOCAL_SCHEMA_VERSION


def _id(*parts: str) -> str:
    return str(uuid5(NAMESPACE_URL, "clearpocket-local-device:" + ":".join(parts)))


def _bounded_id(value: Any, kind: str) -> str:
    source = str(value)
    return source if len(source) <= 36 else _id(kind, source)


def _rows(connection: sqlite3.Connection, table: str) -> list[dict[str, Any]]:
    return [dict(row) for row in connection.execute(f'SELECT * FROM "{table}"')]


def _one(rows: list[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(rows) != 1:
        raise LocalDeviceTransferError(f"Local Device authority must contain exactly one {label}")
    return rows[0]


def _json_strings(value: str, label: str) -> list[str]:
    try:
        result = json.loads(value)
    except json.JSONDecodeError as failure:
        raise LocalDeviceTransferError(f"Local Device {label} is invalid") from failure
    if not isinstance(result, list) or not all(isinstance(item, str) for item in result):
        raise LocalDeviceTransferError(f"Local Device {label} is invalid")
    return result


def _decrypt_attachment(source: Path, destination: Path, key: bytes, expected_hash: str) -> None:
    payload = source.read_bytes()
    if len(payload) <= 4 or payload[:4] != b"BAV1":
        raise LocalDeviceTransferError("Local Device attachment format is invalid")
    combined = payload[4:]
    try:
        plaintext = AESGCM(key).decrypt(combined[:12], combined[12:], None)
    except Exception as failure:
        raise LocalDeviceTransferError("Local Device attachment authentication failed") from failure
    if hashlib.sha256(plaintext).hexdigest() != expected_hash.lower():
        raise LocalDeviceTransferError("Local Device attachment integrity does not match")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.write_bytes(plaintext)
    destination.chmod(0o600)


def convert_staged_local_device(root: Path, owner_email: str) -> tuple[dict[str, Any], Path]:
    """Build the complete portable-import shape from authenticated disposable staging.

    The source remains untouched. Server-derived payment categories and reserve events are rebuilt
    only from durable local identities, ledger rows, and exact signed reserve attribution.
    """
    owner_email = owner_email.strip().lower()
    if "@" not in owner_email or len(owner_email) > 320:
        raise LocalDeviceTransferError("A valid owner email is required for the new server login")
    database_path = root / "authority.sqlite3"
    with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        schema = int(connection.execute("PRAGMA user_version").fetchone()[0])
        if schema != LOCAL_SCHEMA_VERSION:
            raise LocalDeviceTransferError(
                f"Local Device authority must be upgraded to schema {LOCAL_SCHEMA_VERSION} before transfer"
            )
        household = _one(_rows(connection, "households"), "household")
        budget = _one(_rows(connection, "budgets"), "budget")
        memberships = _rows(connection, "memberships")
        owners = [item for item in memberships if item["role"] == "owner" and item["is_active"]]
        owner_membership = _one(owners, "active owner")
        if len(memberships) != 1:
            raise LocalDeviceTransferError(
                "Shared Local Device membership cannot be transferred until every member can reauthorize"
            )
        users = _rows(connection, "users")
        owner = _one([item for item in users if item["id"] == owner_membership["user_id"]], "owner user")
        accounts = _rows(connection, "accounts")
        groups = _rows(connection, "category_groups")
        categories = _rows(connection, "categories")
        payees = _rows(connection, "payees")
        aliases = _rows(connection, "payee_aliases")
        transactions = _rows(connection, "transactions")
        splits = _rows(connection, "transaction_splits")
        allocations = _rows(connection, "allocation_operations")
        reconciliations = _rows(connection, "reconciliations")
        targets = _rows(connection, "category_targets")
        schedules = _rows(connection, "scheduled_transactions")
        attachments = _rows(connection, "attachments")
        debt_terms = _rows(connection, "account_debt_terms")
        rollover = _rows(connection, "cash_rollover_policies")
        reserve_attribution = _rows(connection, "credit_reserve_attributions")

    owner_id = str(owner["id"])
    budget_id = str(budget["id"])
    household_id = str(household["id"])
    created_at = str(household["created_at"])
    reconciliation_by_account: dict[str, dict[str, Any]] = {}
    for item in sorted(reconciliations, key=lambda row: (row["statement_date"], row["created_at"], row["id"])):
        reconciliation_by_account[str(item["account_id"])] = item

    credit_accounts = [item for item in accounts if item["kind"] == "credit"]
    group_ids = {str(item["id"]): _bounded_id(item["id"], "category-group") for item in groups}
    transaction_ids = {str(item["id"]): _bounded_id(item["id"], "transaction") for item in transactions}
    existing_payment_group = next((item for item in groups if item["name"] == "Credit Card Payments"), None)
    payment_group_id = (
        group_ids[str(existing_payment_group["id"])] if existing_payment_group
        else _id(budget_id, "credit-card-payments")
    )
    payment_category_ids = {
        str(item["id"]): _id(budget_id, "credit-payment", str(item["id"]))
        for item in credit_accounts
    }
    server_groups = [{
        "id": group_ids[str(item["id"])], "budget_id": budget_id, "name": item["name"],
        "sort_order": item["sort_order"], "is_archived": bool(item["is_archived"]),
    } for item in groups]
    if credit_accounts and existing_payment_group is None:
        server_groups.append({
            "id": payment_group_id, "budget_id": budget_id,
            "name": "Credit Card Payments", "sort_order": -100, "is_archived": False,
        })

    server_categories = [{
        "id": item["id"], "budget_id": budget_id, "group_id": group_ids[str(item["group_id"])],
        "name": item["name"], "name_key": normalized_category_name(str(item["name"])),
        "sort_order": item["sort_order"], "is_archived": bool(item["is_archived"]),
        "system_type": None, "linked_account_id": None,
        "delegated_user_id": item["delegated_user_id"],
    } for item in categories]
    for account in credit_accounts:
        account_id = str(account["id"])
        name = f"{account['name']} Payment"
        server_categories.append({
            "id": payment_category_ids[account_id], "budget_id": budget_id,
            "group_id": payment_group_id, "name": name,
            "name_key": normalized_category_name(name), "sort_order": 0,
            "is_archived": bool(account["is_closed"]), "system_type": "credit_payment",
            "linked_account_id": account_id, "delegated_user_id": None,
        })

    server_accounts = []
    for item in accounts:
        account_id = str(item["id"])
        reconciliation = reconciliation_by_account.get(account_id)
        server_accounts.append({
            "id": account_id, "budget_id": budget_id, "name": item["name"],
            "account_type": item["kind"], "is_on_budget": bool(item["is_on_budget"]),
            "is_closed": bool(item["is_closed"]),
            "payment_category_id": payment_category_ids.get(account_id),
            "reconciled_balance_minor": reconciliation and reconciliation["statement_balance_minor"],
            "reconciled_at": reconciliation and reconciliation["created_at"],
            "created_at": item["created_at"],
        })

    server_transactions: list[dict[str, Any]] = []
    for item in transactions:
        status = str(item["status"])
        server_transactions.append({
            "id": transaction_ids[str(item["id"])], "budget_id": budget_id, "account_id": item["account_id"],
            "category_id": None, "transfer_id": item["transfer_id"],
            "scheduled_transaction_id": None, "payee_id": item["payee_id"],
            "amount_minor": item["amount_minor"], "occurred_on": item["occurred_on"],
            "payee_name": item["payee_name"], "memo": item["memo"],
            "financial_classification": item["financial_classification"],
            "is_cleared": bool(item["is_cleared"]), "is_reconciled": bool(item["is_reconciled"]),
            "flag": item["flag"], "tags": _json_strings(item["tags_json"], "transaction tags"),
            "attachment_metadata": [], "status": status,
            "voided_at": item["created_at"] if status == "voided" else None,
            "voided_by_user_id": owner_id if status == "voided" else None,
            "void_reason": item["void_reason"],
            "reversal_of_transaction_id": transaction_ids.get(str(item["reversal_of_transaction_id"])) if item["reversal_of_transaction_id"] else None,
            "reversal_transaction_id": transaction_ids.get(str(item["reversal_transaction_id"])) if item["reversal_transaction_id"] else None,
            "created_by_user_id": item["created_by_user_id"] or owner_id,
            "created_at": item["created_at"],
        })
    for account in accounts:
        opening = int(account["opening_balance_minor"])
        if opening == 0:
            continue
        server_transactions.append({
            "id": _id(str(account["id"]), "opening-balance"), "budget_id": budget_id,
            "account_id": account["id"], "category_id": None, "transfer_id": None,
            "scheduled_transaction_id": None, "payee_id": None, "amount_minor": opening,
            "occurred_on": str(account["created_at"])[:10], "payee_name": "Starting Balance",
            "memo": "Balance when account was added", "financial_classification": "opening_balance",
            "is_cleared": True, "is_reconciled": False, "flag": None, "tags": [],
            "attachment_metadata": [], "status": "posted", "voided_at": None,
            "voided_by_user_id": None, "void_reason": None,
            "reversal_of_transaction_id": None, "reversal_transaction_id": None,
            "created_by_user_id": owner_id, "created_at": account["created_at"],
        })

    server_splits = [{
        "id": _bounded_id(item["id"], "transaction-split"),
        "transaction_id": transaction_ids[str(item["transaction_id"])],
        "category_id": item["category_id"], "amount_minor": item["amount_minor"],
        "memo": item["memo"], "financial_classification": None,
    } for item in splits]

    grouped_allocations: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in allocations:
        grouped_allocations[str(item["operation_id"] or item["id"])].append(item)
    server_allocation_operations = []
    server_allocation_postings = []
    for operation_id, items in grouped_allocations.items():
        first = items[0]
        server_allocation_operations.append({
            "id": operation_id, "budget_id": budget_id, "occurred_on": first["occurred_on"],
            "kind": first["kind"], "actor_user_id": first["actor_user_id"] or owner_id,
            "note": first["note"], "source": "local_device_import",
            "reversal_of_id": None, "created_at": first["created_at"],
        })
        amounts: dict[tuple[str, str | None], int] = defaultdict(int)
        for item in items:
            if item["category_id"] is None:
                raise LocalDeviceTransferError("Local Device allocation is missing its destination category")
            amount = int(item["amount_minor"])
            source = item["source_category_id"]
            amounts[("category", str(source)) if source else ("ready_to_assign", None)] -= amount
            amounts[("category", str(item["category_id"]))] += amount
        for index, ((bucket, category_id), amount) in enumerate(sorted(amounts.items(), key=str)):
            if amount:
                server_allocation_postings.append({
                    "id": _id(operation_id, "posting", str(index)), "operation_id": operation_id,
                    "budget_id": budget_id, "bucket": bucket,
                    "category_id": category_id, "amount_minor": amount,
                })

    target_ids = {str(item["category_id"]): _id(str(item["category_id"]), "target") for item in targets}
    server_targets = [{
        "id": target_ids[str(item["category_id"])], "budget_id": budget_id,
        "category_id": item["category_id"], "target_type": item["target_type"],
        "target_amount_minor": item["amount_minor"], "target_date": item["target_date"],
        "recurrence_months": item["recurrence_months"],
        "minimum_contribution_minor": item["minimum_contribution_minor"],
        "priority": item["priority"], "is_active": bool(item["is_active"]),
        "created_by_user_id": owner_id, "created_at": created_at, "updated_at": created_at,
    } for item in targets]
    snoozes = []
    for item in targets:
        months = _json_strings(item["snoozed_months_json"], "target snooze months")
        if item["snoozed_month"] and item["snoozed_month"] not in months:
            months.append(item["snoozed_month"])
        for month in sorted(set(months)):
            snoozes.append({
                "id": _id(str(item["category_id"]), "snooze", month), "budget_id": budget_id,
                "target_id": target_ids[str(item["category_id"])], "month": month,
                "created_by_user_id": owner_id, "created_at": created_at,
            })

    transaction_by_id = {str(item["id"]): item for item in transactions}
    reserve_events = []
    for item in reserve_attribution:
        transaction = transaction_by_id.get(str(item["transaction_id"]))
        if transaction is None or str(transaction["account_id"]) not in payment_category_ids:
            raise LocalDeviceTransferError("Local Device reserve attribution has no credit transaction")
        amount = int(item["amount_minor"])
        local_transaction_id = str(transaction["id"])
        transaction_id = transaction_ids[local_transaction_id]
        reserve_events.append({
            "id": _id(local_transaction_id, str(item["category_id"]), "reserve"),
            "budget_id": budget_id, "credit_account_id": transaction["account_id"],
            "payment_category_id": payment_category_ids[str(transaction["account_id"])],
            "spending_category_id": item["category_id"], "source_transaction_id": transaction_id,
            "transfer_id": None, "occurred_on": transaction["occurred_on"],
            "amount_minor": amount, "kind": "funded_purchase" if amount > 0 else "refund_release",
            "actor_user_id": transaction["created_by_user_id"] or owner_id,
            "created_at": transaction["created_at"],
        })
    transfer_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in transactions:
        if item["transfer_id"]:
            transfer_groups[str(item["transfer_id"])].append(item)
    account_by_id = {str(item["id"]): item for item in accounts}
    for transfer_id, legs in transfer_groups.items():
        if len(legs) != 2 or sum(int(item["amount_minor"]) for item in legs) != 0:
            raise LocalDeviceTransferError("Local Device transfer is incomplete or unbalanced")
        source = next(item for item in legs if int(item["amount_minor"]) < 0)
        destination = next(item for item in legs if int(item["amount_minor"]) > 0)
        source_account = account_by_id[str(source["account_id"])]
        destination_account = account_by_id[str(destination["account_id"])]
        if source_account["kind"] == "credit" and destination_account["kind"] == "credit":
            raise LocalDeviceTransferError("Local Device credit-to-credit transfer is unsupported")
        credit = destination_account if destination_account["kind"] == "credit" else (
            source_account if source_account["kind"] == "credit" else None
        )
        if credit is not None:
            credit_id = str(credit["id"])
            incoming = int(destination["amount_minor"])
            reserve_events.append({
                "id": _id(transfer_id, "payment-reserve"), "budget_id": budget_id,
                "credit_account_id": credit_id,
                "payment_category_id": payment_category_ids[credit_id],
                "spending_category_id": None, "source_transaction_id": None,
                "transfer_id": transfer_id, "occurred_on": source["occurred_on"],
                "amount_minor": -incoming if destination_account["kind"] == "credit" else incoming,
                "kind": "payment" if destination_account["kind"] == "credit" else "payment_reversal",
                "actor_user_id": source["created_by_user_id"] or owner_id,
                "created_at": source["created_at"],
            })

    converted_root = root / "converted"
    attachment_root = converted_root / "attachments"
    attachment_key = (root / "attachment-key.bin").read_bytes()
    if len(attachment_key) != 32:
        raise LocalDeviceTransferError("Local Device attachment key is invalid")
    attachment_rows = []
    for item in attachments:
        attachment_id = str(item["id"])
        server_attachment_id = _bounded_id(attachment_id, "attachment")
        _decrypt_attachment(
            root / "Attachments" / "objects" / str(item["object_name"]),
            attachment_root / server_attachment_id, attachment_key, str(item["sha256"]),
        )
        attachment_rows.append({
            "id": server_attachment_id, "budget_id": budget_id,
            "transaction_id": transaction_ids[str(item["transaction_id"])], "filename": item["filename"],
            "content_type": item["content_type"], "byte_count": item["size_bytes"],
            "sha256": item["sha256"], "storage_key": attachment_id,
            "created_by_user_id": owner_id, "created_at": item["created_at"],
            "detached_at": None, "detached_by_user_id": None, "purge_after": None,
        })

    payload: dict[str, Any] = {
        "user_directory": [{
            "id": owner_id, "email": owner_email, "display_name": owner["display_name"],
            "password_hash": "replaced-during-import", "created_at": created_at,
        }],
        "household": {"id": household_id, "name": household["name"], "owner_user_id": owner_id, "created_at": created_at},
        "household_members": [{
            "id": _id(household_id, owner_id, "membership"), "household_id": household_id,
            "user_id": owner_id, "role": "owner", "is_active": True, "authorization_version": 1,
        }],
        "budget": {"id": budget_id, "household_id": household_id, "name": budget["name"],
                   "currency_code": budget["currency_code"], "allocation_version": len(grouped_allocations),
                   "created_at": budget["created_at"]},
        "category_groups": server_groups, "accounts": server_accounts,
        "account_debt_terms": [{**item, "budget_id": budget_id} for item in debt_terms],
        "categories": server_categories,
        "payees": [{
            "id": item["id"], "household_id": household_id, "display_name": item["name"],
            "name_key": item["normalized_name"], "is_archived": bool(item["is_archived"]),
            "merged_into_payee_id": None, "created_by_user_id": owner_id,
            "created_at": created_at, "updated_at": created_at,
        } for item in payees],
        "payee_aliases": [{
            "id": _bounded_id(item["id"], "payee-alias"), "payee_id": item["payee_id"], "display_name": item["display_name"],
            "name_key": item["normalized_name"], "created_by_user_id": owner_id, "created_at": created_at,
        } for item in aliases],
        "payee_budget_preferences": [{
            "id": _id(str(item["id"]), budget_id, "preference"), "payee_id": item["id"],
            "budget_id": budget_id, "default_category_id": item["default_category_id"],
            "updated_by_user_id": owner_id, "updated_at": created_at,
        } for item in payees if item["default_category_id"]],
        "cash_rollover_policy_changes": [{
            **item,
            "source": item["source"] if item["source"] in {"legacy_migration", "budget_creation", "user_selection"} else "user_selection",
            "actor_user_id": (item["actor_user_id"] if item["source"] == "legacy_migration" else (item["actor_user_id"] or owner_id)),
        } for item in rollover],
        "category_favorites": [{
            "id": _id(owner_id, str(item["id"]), "favorite"), "budget_id": budget_id,
            "user_id": owner_id, "category_id": item["id"], "sort_order": item["favorite_sort_order"],
        } for item in categories if item["is_favorite"]],
        "targets": server_targets, "target_snoozes": snoozes,
        "scheduled_transactions": [{
            **item, "created_by_user_id": owner_id, "created_at": created_at, "updated_at": created_at,
        } for item in schedules],
        "allocation_operations": server_allocation_operations,
        "allocation_postings": server_allocation_postings,
        "transactions": server_transactions, "transaction_splits": server_splits,
        "transaction_attachments": attachment_rows,
        "credit_card_reserve_events": reserve_events,
    }
    return payload, converted_root
