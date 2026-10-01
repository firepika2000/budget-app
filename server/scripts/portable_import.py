#!/usr/bin/env python3
"""Validate-then-commit import of portable data into a brand-new local authority."""

from __future__ import annotations

from datetime import date, datetime
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import tempfile
from typing import Any
from uuid import uuid4

from sqlalchemy import Date, DateTime, func, insert, select, update

from app import models as _models  # noqa: F401 - register every mapped table with Base metadata
from app.attachment_storage import AttachmentStorage
from app.database import Base, build_session_factory
from app.security import hash_password
from scripts.local_server import (
    LocalServerConfiguration, LocalServerError, exclusive_server_lock, migrate,
    record_restore_verification, sha256_file,
)
from scripts.portable_archive import PortableArchiveError, extract_and_validate_archive, _decrypt


class PortableImportError(RuntimeError):
    pass


SECTION_TABLE_ORDER = (
    ("user_directory", "users"),
    ("household", "households"),
    ("household_members", "memberships"),
    ("household_invitations", "invitations"),
    ("budget", "budgets"),
    ("category_groups", "category_groups"),
    ("accounts", "accounts"),
    ("account_debt_terms", "account_debt_terms"),
    ("categories", "categories"),
    ("payees", "payees"),
    ("payee_aliases", "payee_aliases"),
    ("payee_budget_preferences", "payee_budget_preferences"),
    ("budget_grants", "budget_grants"),
    ("access_profiles", "budget_access_profiles"),
    ("capability_grants", "capability_grants"),
    ("resource_grants", "resource_grants"),
    ("cash_rollover_policy_changes", "cash_rollover_policy_changes"),
    ("category_favorites", "category_favorites"),
    ("delegated_budget_policies", "delegated_budget_policies"),
    ("delegated_category_rules", "delegated_category_rules"),
    ("targets", "category_targets"),
    ("target_snoozes", "category_target_snoozes"),
    ("scheduled_transactions", "scheduled_transactions"),
    ("legacy_monthly_assignments", "monthly_assignments"),
    ("allocation_operations", "allocation_operations"),
    ("allocation_postings", "allocation_postings"),
    ("transactions", "transactions"),
    ("transaction_splits", "transaction_splits"),
    ("transaction_changes", "transaction_changes"),
    ("transaction_attachments", "transaction_attachments"),
    ("credit_card_reserve_events", "credit_card_reserve_events"),
    ("allowance_plans", "allowance_plans"),
    ("allowance_splits", "allowance_splits"),
    ("allowance_issuances", "allowance_issuances"),
    ("requests", "financial_requests"),
    ("request_actions", "request_actions"),
    ("import_batches", "import_batches"),
    ("household_access_events", "household_access_events"),
)


DEFERRED_FIELDS = {
    "accounts": {"payment_category_id"},
    "payees": {"merged_into_payee_id"},
    "allocation_operations": {"reversal_of_id"},
    "transactions": {"reversal_of_transaction_id", "reversal_transaction_id"},
}


def _rows(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list) and all(isinstance(item, dict) for item in value):
        return value
    raise PortableImportError("Portable data section has an invalid shape")


def _coerce_row(table, source: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for column in table.columns:
        if column.name not in source:
            continue
        value = source[column.name]
        if value is not None and isinstance(column.type, DateTime) and isinstance(value, str):
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        elif value is not None and isinstance(column.type, Date) and not isinstance(column.type, DateTime) and isinstance(value, str):
            value = date.fromisoformat(value)
        result[column.name] = value
    return result


def _financial_observations_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    transactions: dict[tuple[str, str], int] = {}
    for row in _rows(payload.get("transactions", [])):
        key = (str(row["account_id"]), str(row["status"]))
        transactions[key] = transactions.get(key, 0) + int(row["amount_minor"])
    allocations: dict[tuple[str, str], int] = {}
    for row in _rows(payload.get("allocation_postings", [])):
        key = (str(row["bucket"]), str(row.get("category_id") or ""))
        allocations[key] = allocations.get(key, 0) + int(row["amount_minor"])
    reserves: dict[str, int] = {}
    for row in _rows(payload.get("credit_card_reserve_events", [])):
        key = str(row["payment_category_id"])
        reserves[key] = reserves.get(key, 0) + int(row["amount_minor"])
    return {
        "transaction_count": len(_rows(payload.get("transactions", []))),
        "transactions": transactions,
        "allocation_count": len(_rows(payload.get("allocation_postings", []))),
        "allocations": allocations,
        "reserve_count": len(_rows(payload.get("credit_card_reserve_events", []))),
        "reserves": reserves,
    }


def _financial_observations_from_database(engine) -> dict[str, Any]:
    tables = Base.metadata.tables
    with engine.connect() as connection:
        payload = {
            "transactions": [dict(row._mapping) for row in connection.execute(select(tables["transactions"]))],
            "allocation_postings": [dict(row._mapping) for row in connection.execute(select(tables["allocation_postings"]))],
            "credit_card_reserve_events": [dict(row._mapping) for row in connection.execute(select(tables["credit_card_reserve_events"]))],
        }
    return _financial_observations_from_payload(payload)


def import_payload(
    payload: dict[str, Any], extracted_root: Path, configuration: LocalServerConfiguration,
    owner_password: str,
) -> None:
    import_payload_into_authority(
        payload,
        extracted_root,
        database_url=configuration.environment()["BUDGET_APP_DATABASE_URL"],
        attachment_path=configuration.attachment_path,
        deployment_secret=configuration.jwt_secret,
        attachment_encryption_key=configuration.attachment_encryption_key,
        owner_password=owner_password,
    )


def import_payload_into_authority(
    payload: dict[str, Any], extracted_root: Path, *, database_url: str,
    attachment_path: Path, deployment_secret: str, attachment_encryption_key: str,
    owner_password: str,
) -> None:
    """Commit a validated portable payload only into a completely empty authority.

    This boundary is deliberately database-provider neutral.  It is suitable for the temporary
    SQLite authority used by personal-server import and for a newly installed PostgreSQL customer
    server.  It never merges into, replaces, or partially overlays an existing household.
    """
    if len(owner_password) < 12:
        raise PortableImportError("Imported owner password must contain at least 12 characters")
    owner_id = str(payload["household"]["owner_user_id"])
    tables = Base.metadata.tables
    deferred_updates: list[tuple[Any, str, dict[str, Any]]] = []
    attachment_rows: list[dict[str, Any]] = []
    factory = build_session_factory(database_url)
    engine = factory.kw["bind"]
    storage = AttachmentStorage(
        str(attachment_path), deployment_secret, attachment_encryption_key,
    )
    written_storage_keys: list[str] = []
    try:
        with engine.begin() as connection:
            if engine.dialect.name == "sqlite":
                connection.exec_driver_sql("PRAGMA foreign_keys = ON")
            occupied = {
                name: int(connection.scalar(select(func.count()).select_from(tables[name])) or 0)
                for name in ("setup_state", "users", "households", "budgets")
            }
            if any(occupied.values()):
                raise PortableImportError(
                    "Portable import requires a new empty authority; existing data was preserved"
                )
            existing_objects = [item for item in attachment_path.iterdir()] if attachment_path.exists() else []
            if existing_objects:
                raise PortableImportError(
                    "Portable import requires empty attachment storage; existing objects were preserved"
                )
            connection.execute(insert(tables["setup_state"]), [{"id": 1, "completed_at": datetime.now().astimezone()}])
            for section, table_name in SECTION_TABLE_ORDER:
                rows = _rows(payload.get(section, []))
                table = tables[table_name]
                prepared: list[dict[str, Any]] = []
                for source in rows:
                    row = _coerce_row(table, source)
                    if table_name == "users":
                        row["password_hash"] = hash_password(owner_password) if row.get("id") == owner_id else hash_password(secrets.token_urlsafe(48))
                    elif table_name == "invitations":
                        row["token_hash"] = hashlib.sha256(secrets.token_bytes(48)).hexdigest()
                    elif table_name == "transaction_attachments":
                        row["storage_key"] = str(uuid4())
                        attachment_rows.append(row)
                    deferred = DEFERRED_FIELDS.get(table_name, set())
                    values: dict[str, Any] = {}
                    for name in deferred:
                        value = row.pop(name, None)
                        if value is not None:
                            values[name] = value
                    if values:
                        deferred_updates.append((table, str(row["id"]), values))
                    prepared.append(row)
                if prepared:
                    connection.execute(insert(table), prepared)
            for table, identifier, values in deferred_updates:
                connection.execute(update(table).where(table.c.id == identifier).values(**values))
            for row in attachment_rows:
                if row.get("detached_at") is not None:
                    continue
                plaintext = (extracted_root / "attachments" / str(row["id"])).read_bytes()
                storage.write(str(row["storage_key"]), plaintext)
                written_storage_keys.append(str(row["storage_key"]))
            if _financial_observations_from_payload(payload) != _financial_observations_from_connection(connection):
                raise PortableImportError("Portable financial data changed during import")
    except PortableImportError:
        for storage_key in written_storage_keys:
            storage.delete(storage_key)
        raise
    except Exception as failure:
        for storage_key in written_storage_keys:
            storage.delete(storage_key)
        raise PortableImportError("Portable data could not be committed to the new authority") from failure


def _financial_observations_from_connection(connection) -> dict[str, Any]:
    tables = Base.metadata.tables
    payload = {
        "transactions": [dict(row._mapping) for row in connection.execute(select(tables["transactions"]))],
        "allocation_postings": [dict(row._mapping) for row in connection.execute(select(tables["allocation_postings"]))],
        "credit_card_reserve_events": [dict(row._mapping) for row in connection.execute(select(tables["credit_card_reserve_events"]))],
    }
    return _financial_observations_from_payload(payload)


def import_portable_archive(
    encrypted: Path, destination: Path, server_directory: Path, owner_password: str,
) -> LocalServerConfiguration:
    encrypted = encrypted.expanduser().resolve()
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise PortableImportError("Portable import requires a new destination")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".budget-portable-import-", dir=destination.parent) as name:
        temporary = Path(name)
        decrypted = temporary / "portable.tar.gz"
        _decrypt(encrypted, decrypted)
        extracted = temporary / "verified"
        payload = extract_and_validate_archive(decrypted, extracted)
        before = _financial_observations_from_payload(payload)
        authority = temporary / "authority"
        configuration = LocalServerConfiguration.load_or_create(authority)
        with exclusive_server_lock(configuration):
            migrate(configuration, server_directory)
            import_payload(payload, extracted, configuration, owner_password)
        # Re-exporting through the API is the later canonical-observation gate. At this layer, prove
        # every exact source row was accepted and the database is structurally sound before cutover.
        from scripts.local_server import _validate_sqlite_snapshot
        _validate_sqlite_snapshot(configuration.database_path)
        engine = build_session_factory(configuration.environment()["BUDGET_APP_DATABASE_URL"]).kw["bind"]
        if before != _financial_observations_from_database(engine):
            raise PortableImportError("Portable financial data changed during import")
        record_restore_verification(configuration, encrypted, "portable_archive")
        os.rename(authority, destination)
    return LocalServerConfiguration.load_or_create(destination)


def import_portable_archive_into_server(
    encrypted: Path, owner_password: str,
) -> None:
    """Restore into the empty database/object store configured by the process environment."""
    required = {
        "BUDGET_APP_DATABASE_URL", "BUDGET_APP_JWT_SECRET",
        "BUDGET_APP_ATTACHMENT_STORAGE_PATH", "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY",
        "BUDGET_APP_RECOVERY_STATUS_PATH",
    }
    missing = sorted(key for key in required if not os.environ.get(key, "").strip())
    if missing:
        raise PortableImportError(
            "Server import configuration is incomplete: " + ", ".join(missing)
        )
    encrypted = encrypted.expanduser().resolve()
    if not encrypted.is_file() or encrypted.is_symlink():
        raise PortableImportError("Encrypted portable archive was not found")
    attachment_path = Path(os.environ["BUDGET_APP_ATTACHMENT_STORAGE_PATH"]).resolve()
    recovery_status_path = Path(os.environ["BUDGET_APP_RECOVERY_STATUS_PATH"]).resolve()
    with tempfile.TemporaryDirectory(prefix=".budget-portable-server-import-") as name:
        temporary = Path(name)
        decrypted = temporary / "portable.tar.gz"
        _decrypt(encrypted, decrypted)
        extracted = temporary / "verified"
        payload = extract_and_validate_archive(decrypted, extracted)
        import_payload_into_authority(
            payload,
            extracted,
            database_url=os.environ["BUDGET_APP_DATABASE_URL"],
            attachment_path=attachment_path,
            deployment_secret=os.environ["BUDGET_APP_JWT_SECRET"],
            attachment_encryption_key=os.environ["BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"],
            owner_password=owner_password,
        )
        engine = build_session_factory(os.environ["BUDGET_APP_DATABASE_URL"]).kw["bind"]
        if _financial_observations_from_payload(payload) != _financial_observations_from_database(engine):
            raise PortableImportError("Portable financial observations changed after server import")
        _record_server_restore_verification(recovery_status_path, encrypted)


def _record_server_restore_verification(status: Path, source: Path) -> None:
    if status.is_symlink():
        raise PortableImportError("Server recovery status path must not be a symbolic link")
    status.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload: dict[str, object] = {
        "state": "verified",
        "verified_at": datetime.now().astimezone().isoformat(),
        "source_provider": "portable_archive",
        "source_archive_sha256": sha256_file(source),
        "database_integrity": "ok",
        "foreign_keys": "ok",
    }
    temporary = status.with_name(f".{status.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, status)


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--data-directory", type=Path)
    destination.add_argument(
        "--server-environment", action="store_true",
        help="import into a new empty authority configured by BUDGET_APP_* environment variables",
    )
    args = parser.parse_args(arguments)
    try:
        password = getpass.getpass("New local owner password: ")
        confirmation = getpass.getpass("Confirm new local owner password: ")
        if password != confirmation:
            raise PortableImportError("Owner password confirmation does not match")
        if args.server_environment:
            import_portable_archive_into_server(
                args.archive, password
            )
            print("Portable budget imported into the new empty server authority")
        else:
            result = import_portable_archive(
                args.archive, args.data_directory, Path(__file__).resolve().parents[1], password
            )
            print(f"Portable budget imported into new local authority: {result.data_directory}")
        print("All devices must sign in again against the new authority.")
        return 0
    except (OSError, LocalServerError, PortableArchiveError, PortableImportError) as failure:
        print(f"Portable import error: {failure}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
