"""Lossless server-authority projection for a new single-user Local Device authority.

This module performs representation mapping only. It never mutates either provider and it never
recomputes financial consequences: transaction, allocation, and reserve ledgers remain the source
of truth. The native client must still stage, reopen, compare observations, and cold-activate the
candidate before changing providers.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
from typing import Any

from fastapi.encoders import jsonable_encoder
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import (
    Account, AccountDebtTerms, AllocationOperation, AllocationPosting, Budget,
    CashRolloverPolicyChange, Category, CategoryFavorite, CategoryGroup, CategoryTarget,
    CategoryTargetSnooze, CreditCardReserveEvent, Household, Payee, PayeeAlias,
    DebtPayoffPlan, ImportBatch, PayeeBudgetPreference, ScheduledTransaction, Transaction, TransactionAttachment,
    Reconciliation, TransactionChange, TransactionSplit, User,
)


FORMAT = "com.clearpocket.local-device-transfer"
VERSION = 1


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    return value.isoformat()


def _canonical(value: object) -> bytes:
    return json.dumps(jsonable_encoder(value), sort_keys=True, separators=(",", ":")).encode()


def source_revision(projection: dict[str, Any]) -> str:
    """Hash authority content while excluding response-generation metadata.

    Native transfer downloads attachments between two projection reads. A stable revision lets it
    prove the authority did not change during that interval; including ``generated_at`` would make
    every otherwise-identical read appear different and render that safety check unusable.
    """
    content = {
        key: value for key, value in projection.items()
        if key not in {"generated_at", "source_revision"}
    }
    return hashlib.sha256(_canonical(content)).hexdigest()


def _allocation_rows(
    operations: list[AllocationOperation], postings: list[AllocationPosting]
) -> list[dict[str, Any]]:
    by_operation: dict[str, list[AllocationPosting]] = defaultdict(list)
    for posting in postings:
        by_operation[posting.operation_id].append(posting)
    rows: list[dict[str, Any]] = []
    for operation in operations:
        values = by_operation[operation.id]
        if sum(item.amount_minor for item in values) != 0:
            raise ValueError("Allocation operation is not balanced")
        ready = [item for item in values if item.bucket == "ready_to_assign"]
        categories = [item for item in values if item.bucket == "category"]
        if ready:
            if len(ready) != 1:
                raise ValueError("Allocation operation has multiple Ready to Assign postings")
            mapped = [(item.id, None, item.category_id, item.amount_minor) for item in categories]
        else:
            negative = [item for item in categories if item.amount_minor < 0]
            positive = [item for item in categories if item.amount_minor > 0]
            if len(negative) == 1:
                mapped = [(item.id, negative[0].category_id, item.category_id, item.amount_minor) for item in positive]
            elif len(positive) == 1:
                mapped = [(item.id, item.category_id, positive[0].category_id, -item.amount_minor) for item in negative]
            else:
                if not negative or not positive:
                    raise ValueError("Allocation operation has no portable category movement")
                # Local Device stores directed source/destination rows. A balanced many-to-many
                # operation can be represented losslessly by deterministically matching its
                # negative and positive postings; the shared operation id retains its atomic audit
                # identity while every category's exact net posting remains unchanged.
                sources = [[item, -item.amount_minor] for item in sorted(negative, key=lambda row: row.id)]
                destinations = [[item, item.amount_minor] for item in sorted(positive, key=lambda row: row.id)]
                mapped = []
                source_index = destination_index = 0
                while source_index < len(sources) and destination_index < len(destinations):
                    source, source_remaining = sources[source_index]
                    destination, destination_remaining = destinations[destination_index]
                    amount = min(source_remaining, destination_remaining)
                    mapped.append((f"{operation.id}:{source.id}:{destination.id}",
                                   source.category_id, destination.category_id, amount))
                    sources[source_index][1] -= amount
                    destinations[destination_index][1] -= amount
                    if sources[source_index][1] == 0:
                        source_index += 1
                    if destinations[destination_index][1] == 0:
                        destination_index += 1
                if source_index != len(sources) or destination_index != len(destinations):
                    raise ValueError("Allocation operation could not be balanced for Local Device")
        for posting_id, source_category_id, category_id, amount_minor in mapped:
            rows.append({
                "id": posting_id,
                "operation_id": operation.id,
                "budget_id": operation.budget_id,
                "source_category_id": source_category_id,
                "category_id": category_id,
                "amount_minor": amount_minor,
                "occurred_on": _iso(operation.occurred_on),
                "kind": operation.kind,
                "actor_user_id": operation.actor_user_id,
                "note": operation.note,
                "created_at": _iso(operation.created_at),
            })
    return rows


def unsupported_allocation_operation_count(db: Session, budget_id: str) -> int:
    """Count canonical operations that the current Local Device command rows cannot express."""
    operations = list(db.scalars(select(AllocationOperation).where(AllocationOperation.budget_id == budget_id)))
    operation_ids = [item.id for item in operations]
    postings = list(db.scalars(select(AllocationPosting).where(
        AllocationPosting.operation_id.in_(operation_ids)
    ))) if operation_ids else []
    by_operation: dict[str, list[AllocationPosting]] = defaultdict(list)
    for posting in postings:
        by_operation[posting.operation_id].append(posting)
    unsupported = 0
    for operation in operations:
        values = by_operation[operation.id]
        ready = [item for item in values if item.bucket == "ready_to_assign"]
        categories = [item for item in values if item.bucket == "category"]
        balanced = bool(values) and sum(item.amount_minor for item in values) == 0
        representable = balanced and (
            (len(ready) == 1 and bool(categories))
            or (not ready and any(item.amount_minor < 0 for item in categories)
                and any(item.amount_minor > 0 for item in categories))
        )
        if not representable:
            unsupported += 1
    return unsupported


def build_local_device_projection(
    db: Session, *, budget: Budget, household: Household, owner: User
) -> dict[str, Any]:
    accounts = list(db.scalars(select(Account).where(Account.budget_id == budget.id).order_by(Account.id)))
    groups = list(db.scalars(select(CategoryGroup).where(CategoryGroup.budget_id == budget.id).order_by(CategoryGroup.sort_order, CategoryGroup.id)))
    categories = list(db.scalars(select(Category).where(Category.budget_id == budget.id).order_by(Category.sort_order, Category.id)))
    portable_categories = [item for item in categories if item.system_type is None]
    portable_group_ids = {item.group_id for item in portable_categories}
    portable_groups = [item for item in groups if item.id in portable_group_ids]
    transactions = list(db.scalars(select(Transaction).where(Transaction.budget_id == budget.id).order_by(Transaction.occurred_on, Transaction.id)))
    transaction_ids = [item.id for item in transactions]
    splits = list(db.scalars(select(TransactionSplit).where(TransactionSplit.transaction_id.in_(transaction_ids)))) if transaction_ids else []
    splits_by_transaction: dict[str, list[TransactionSplit]] = defaultdict(list)
    for split in splits:
        splits_by_transaction[split.transaction_id].append(split)

    operations = list(db.scalars(select(AllocationOperation).where(AllocationOperation.budget_id == budget.id).order_by(AllocationOperation.occurred_on, AllocationOperation.id)))
    operation_ids = [item.id for item in operations]
    postings = list(db.scalars(select(AllocationPosting).where(AllocationPosting.operation_id.in_(operation_ids)))) if operation_ids else []
    allocation_rows = _allocation_rows(operations, postings)

    favorites = {item.category_id: item for item in db.scalars(select(CategoryFavorite).where(
        CategoryFavorite.budget_id == budget.id, CategoryFavorite.user_id == owner.id,
    ))}
    preferences = {item.payee_id: item for item in db.scalars(select(PayeeBudgetPreference).where(
        PayeeBudgetPreference.budget_id == budget.id,
    ))}
    payees = list(db.scalars(select(Payee).where(Payee.household_id == household.id).order_by(Payee.id)))
    payee_ids = [item.id for item in payees]
    aliases = list(db.scalars(select(PayeeAlias).where(PayeeAlias.payee_id.in_(payee_ids)).order_by(PayeeAlias.id))) if payee_ids else []
    targets = list(db.scalars(select(CategoryTarget).where(CategoryTarget.budget_id == budget.id).order_by(CategoryTarget.category_id)))
    target_ids = [item.id for item in targets]
    snoozes: dict[str, list[str]] = defaultdict(list)
    if target_ids:
        for item in db.scalars(select(CategoryTargetSnooze).where(CategoryTargetSnooze.target_id.in_(target_ids))):
            snoozes[item.target_id].append(_iso(item.month) or "")
    reserve_events = list(db.scalars(select(CreditCardReserveEvent).where(
        CreditCardReserveEvent.budget_id == budget.id
    ).order_by(CreditCardReserveEvent.occurred_on, CreditCardReserveEvent.id)))
    reserve_attribution: dict[tuple[str, str], int] = defaultdict(int)
    for item in reserve_events:
        if item.source_transaction_id and item.spending_category_id:
            reserve_attribution[(item.source_transaction_id, item.spending_category_id)] += item.amount_minor

    attachment_rows = list(db.scalars(select(TransactionAttachment).where(
        TransactionAttachment.budget_id == budget.id,
        TransactionAttachment.detached_at.is_(None),
    ).order_by(TransactionAttachment.created_at, TransactionAttachment.id)))
    attachment_tombstones = list(db.scalars(select(TransactionAttachment).where(
        TransactionAttachment.budget_id == budget.id,
        TransactionAttachment.detached_at.is_not(None),
    ).order_by(TransactionAttachment.detached_at, TransactionAttachment.id)))
    import_batches = list(db.scalars(select(ImportBatch).where(
        ImportBatch.budget_id == budget.id
    ).order_by(ImportBatch.created_at, ImportBatch.id)))

    projection: dict[str, Any] = {
        "format": FORMAT,
        "version": VERSION,
        "generated_at": _iso(datetime.now(timezone.utc)),
        "authority_created_at": _iso(household.created_at),
        "identity": {
            "household_id": household.id, "household_name": household.name,
            "owner_user_id": owner.id, "owner_display_name": owner.display_name,
            "budget_id": budget.id, "budget_name": budget.name,
            "currency_code": budget.currency_code,
        },
        "accounts": [{
            "id": item.id, "budget_id": budget.id, "name": item.name,
            "kind": item.account_type, "is_on_budget": item.is_on_budget,
            "is_closed": item.is_closed, "opening_balance_minor": 0,
            "created_at": _iso(item.created_at),
        } for item in accounts],
        "groups": [{
            "id": item.id, "budget_id": budget.id, "name": item.name,
            "sort_order": item.sort_order, "is_archived": item.is_archived,
        } for item in portable_groups],
        "categories": [{
            "id": item.id, "budget_id": budget.id, "group_id": item.group_id,
            "name": item.name, "icon_name": item.icon_name, "note": item.note,
            "delegated_user_id": None, "is_archived": item.is_archived,
            "sort_order": item.sort_order, "is_favorite": item.id in favorites,
            "favorite_sort_order": favorites[item.id].sort_order if item.id in favorites else 0,
            "is_essential": item.is_essential,
            "is_emergency_fund": item.is_emergency_fund,
        } for item in portable_categories],
        "payees": [{
            "id": item.id, "budget_id": budget.id, "name": item.display_name,
            # A merged source deliberately clears its active namespace key on Server.
            # Local Device stores a non-null string, while redirect identity remains authoritative.
            "normalized_name": item.name_key or "",
            "default_category_id": preferences[item.id].default_category_id if item.id in preferences else None,
            "is_archived": item.is_archived,
            "merged_into_payee_id": item.merged_into_payee_id,
        } for item in payees],
        "payee_aliases": [{
            "id": item.id, "payee_id": item.payee_id, "display_name": item.display_name,
            "normalized_name": item.name_key,
        } for item in aliases],
        "transactions": [{
            "id": item.id, "budget_id": budget.id, "account_id": item.account_id,
            "payee_id": item.payee_id, "payee_name": item.payee_name,
            "amount_minor": item.amount_minor, "occurred_on": _iso(item.occurred_on),
            "memo": item.memo, "is_cleared": item.is_cleared,
            "is_reconciled": item.is_reconciled, "status": item.status,
            "transfer_id": item.transfer_id,
            "scheduled_transaction_id": item.scheduled_transaction_id,
            "flag": item.flag, "tags": item.tags,
            "financial_classification": item.financial_classification,
            "void_reason": item.void_reason,
            "reversal_of_transaction_id": item.reversal_of_transaction_id,
            "reversal_transaction_id": item.reversal_transaction_id,
            "created_by_user_id": item.created_by_user_id, "created_at": _iso(item.created_at),
            "splits": ([{
                "id": split.id, "category_id": split.category_id,
                "amount_minor": split.amount_minor, "memo": split.memo,
                "financial_classification": split.financial_classification,
            } for split in sorted(splits_by_transaction[item.id], key=lambda value: value.id)] or ([{
                "id": f"{item.id}-category", "category_id": item.category_id,
                "amount_minor": item.amount_minor, "memo": "",
                "financial_classification": item.financial_classification,
            }] if item.category_id is not None else [])),
        } for item in transactions],
        "allocations": allocation_rows,
        "reconciliations": [{
            "id": item.id, "account_id": item.account_id,
            "statement_date": _iso(item.statement_date),
            "statement_balance_minor": item.statement_balance_minor,
            "actor_user_id": item.actor_user_id,
            "cleared_balance_before_minor": item.cleared_balance_before_minor,
            "reconciled_transaction_count": item.reconciled_transaction_count,
            "adjustment_transaction_id": item.adjustment_transaction_id,
            "created_at": _iso(item.created_at),
        } for item in db.scalars(select(Reconciliation).where(
            Reconciliation.budget_id == budget.id
        ).order_by(Reconciliation.statement_date, Reconciliation.created_at, Reconciliation.id))],
        "targets": [{
            "category_id": item.category_id, "target_type": item.target_type,
            "amount_minor": item.target_amount_minor, "cadence": "monthly",
            "effective_month": f"{item.created_at.date().isoformat()[:7]}-01",
            "snoozed_month": max(snoozes[item.id], default=None),
            "target_date": _iso(item.target_date), "recurrence_months": item.recurrence_months,
            "minimum_contribution_minor": item.minimum_contribution_minor,
            "priority": item.priority, "is_active": item.is_active,
            "snoozed_months": sorted(snoozes[item.id]),
        } for item in targets],
        "schedules": [{
            "id": item.id, "budget_id": budget.id, "account_id": item.account_id,
            "destination_account_id": item.destination_account_id,
            "category_id": item.category_id, "payee_id": item.payee_id,
            "name": item.name, "amount_minor": item.amount_minor,
            "next_date": _iso(item.next_date), "recurrence_unit": item.recurrence_unit,
            "interval_count": item.interval_count, "memo": item.memo,
            "end_date": _iso(item.end_date),
            "remaining_occurrences": item.remaining_occurrences,
            "is_active": item.is_active,
            "financial_classification": item.financial_classification,
            "last_realized_on": _iso(item.last_realized_on),
        } for item in db.scalars(select(ScheduledTransaction).where(
            ScheduledTransaction.budget_id == budget.id
        ).order_by(ScheduledTransaction.id))],
        "attachments": [{
            "id": item.id, "transaction_id": item.transaction_id,
            "filename": item.filename, "content_type": item.content_type,
            "size_bytes": item.byte_count, "sha256": item.sha256,
            "object_name": item.id, "created_at": _iso(item.created_at),
        } for item in attachment_rows],
        # Detached objects are deliberately not downloaded into a new authority. Their immutable
        # lifecycle metadata is still part of the household record, matching portable-export
        # semantics while avoiding resurrection of content the user explicitly removed.
        "attachment_tombstones": [{
            "id": item.id, "budget_id": budget.id,
            "transaction_id": item.transaction_id,
            "filename": item.filename, "content_type": item.content_type,
            "size_bytes": item.byte_count, "sha256": item.sha256,
            "created_at": _iso(item.created_at),
            "detached_at": _iso(item.detached_at),
            "detached_by_user_id": item.detached_by_user_id,
            "purge_after": _iso(item.purge_after),
            "tombstone_object_name": None,
        } for item in attachment_tombstones],
        "statement_imports": [{
            "id": item.id, "budget_id": item.budget_id, "account_id": item.account_id,
            "status": item.status, "version": item.version + 1,
            "source_format": item.source_format, "candidate_count": item.candidate_count,
            "created_at": _iso(item.created_at),
            "payload": {
                "id": item.id, "budget_id": item.budget_id, "account_id": item.account_id,
                "status": item.status, "version": item.version + 1,
                "source_format": item.source_format, "candidate_count": item.candidate_count,
                "created_at": _iso(item.created_at),
                "candidates": [{
                    **candidate,
                    "exact_transaction_ids": [], "possible_transaction_ids": [],
                    "suggestions_truncated": False, "duplicate_source_row": False,
                } for candidate in item.candidates],
            },
        } for item in import_batches],
        "debt_terms": [{
            key: _iso(value) if key in {"promotional_ends_on", "updated_at"} else value
            for key, value in vars(item).items() if not key.startswith("_") and key != "budget_id"
        } for item in db.scalars(select(AccountDebtTerms).where(AccountDebtTerms.budget_id == budget.id))],
        # Payoff scenarios are personal forecast preferences. A single-user Local Device transfer
        # carries only the owner's plan and never exposes another household member's preferences.
        "debt_payoff_plans": [{
            "id": item.id, "budget_id": item.budget_id, "user_id": item.user_id,
            "strategy": item.strategy, "rollover": item.rollover,
            "extra_payment_minor": item.extra_payment_minor,
            "account_ids": item.account_ids, "custom_order": item.custom_order,
            "target_date": _iso(item.target_date), "updated_at": _iso(item.updated_at),
        } for item in db.scalars(select(DebtPayoffPlan).where(
            DebtPayoffPlan.budget_id == budget.id,
            DebtPayoffPlan.user_id == owner.id,
        ))],
        "cash_rollover_policies": [{
            "id": item.id, "budget_id": budget.id,
            "effective_month": _iso(item.effective_month), "policy": item.policy,
            "version": item.version, "source": item.source,
            "actor_user_id": item.actor_user_id, "created_at": _iso(item.created_at),
        } for item in db.scalars(select(CashRolloverPolicyChange).where(
            CashRolloverPolicyChange.budget_id == budget.id
        ).order_by(CashRolloverPolicyChange.version))],
        "credit_reserve_attributions": [{
            "transaction_id": transaction_id, "category_id": category_id,
            "amount_minor": amount,
        } for (transaction_id, category_id), amount in sorted(reserve_attribution.items()) if amount != 0],
        "transaction_changes": [{
            "id": item.id, "budget_id": budget.id, "transaction_id": item.transaction_id,
            "actor_user_id": item.actor_user_id, "action": item.action,
            "before_json": item.before_json, "after_json": item.after_json,
            "created_at": _iso(item.created_at),
        } for item in db.scalars(select(TransactionChange).where(
            TransactionChange.budget_id == budget.id
        ).order_by(TransactionChange.created_at, TransactionChange.id))],
        "credit_reserve_events": [{
            "id": item.id, "budget_id": budget.id,
            "credit_account_id": item.credit_account_id,
            "payment_category_id": item.payment_category_id,
            "spending_category_id": item.spending_category_id,
            "source_transaction_id": item.source_transaction_id,
            "transfer_id": item.transfer_id, "occurred_on": _iso(item.occurred_on),
            "amount_minor": item.amount_minor, "kind": item.kind,
            "actor_user_id": item.actor_user_id, "created_at": _iso(item.created_at),
        } for item in reserve_events],
        "observations": {
            "transaction_count": len(transactions),
            "transactions": [{"account_id": account_id, "status": status, "amount_minor": amount}
                             for (account_id, status), amount in sorted(_transaction_observations(transactions).items())],
            "allocation_count": len(postings),
            "allocations": [{"bucket": bucket, "category_id": category_id or None, "amount_minor": amount}
                            for (bucket, category_id), amount in sorted(_allocation_observations(postings).items())],
            "reserve_count": len(reserve_events),
            "reserves": [{"payment_category_id": category_id, "amount_minor": amount}
                         for category_id, amount in sorted(_reserve_observations(reserve_events).items())],
        },
    }
    projection["source_revision"] = source_revision(projection)
    return projection


def _transaction_observations(values: list[Transaction]) -> dict[tuple[str, str], int]:
    result: dict[tuple[str, str], int] = defaultdict(int)
    for item in values:
        result[(item.account_id, item.status)] += item.amount_minor
    return result


def _allocation_observations(values: list[AllocationPosting]) -> dict[tuple[str, str], int]:
    result: dict[tuple[str, str], int] = defaultdict(int)
    for item in values:
        result[(item.bucket, item.category_id or "")] += item.amount_minor
    return result


def _reserve_observations(values: list[CreditCardReserveEvent]) -> dict[str, int]:
    result: dict[str, int] = defaultdict(int)
    for item in values:
        result[item.payment_category_id] += item.amount_minor
    return result
