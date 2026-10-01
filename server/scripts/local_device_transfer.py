#!/usr/bin/env python3
"""Authenticate and stage an iPhone Local Device backup for provider transfer."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import struct
import tempfile
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


FORMAT = "com.clearpocket.local-backup"
FORMAT_VERSION = 1
LOCAL_SCHEMA_VERSION = 4
LOCAL_APPLICATION_ID = 0x42554447
MAGIC = b"CPBF1"
MAXIMUM_CHUNK_BYTES = 1_100_000
MAXIMUM_FILES = 25_000
MAXIMUM_MANIFEST_BYTES = 16 * 1024 * 1024


class LocalDeviceTransferError(RuntimeError):
    pass


def decode_recovery_key(value: str) -> bytes:
    value = value.strip().replace("-", "+").replace("_", "/")
    value += "=" * ((4 - len(value) % 4) % 4)
    try:
        key = base64.b64decode(value, validate=True)
    except ValueError as failure:
        raise LocalDeviceTransferError("Local Device recovery key is invalid") from failure
    if len(key) != 32:
        raise LocalDeviceTransferError("Local Device recovery key must contain exactly 32 bytes")
    return key


def canonical_json(value: Any) -> bytes:
    # Foundation JSONEncoder (used by LocalDeviceBackupService) escapes forward slashes even with
    # sortedKeys.  Preserve those exact authenticated bytes rather than accepting a Python-native
    # reserialization that no real iPhone generation signs.
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode().replace(
        b"/", b"\\/"
    )


def _safe_component(value: str) -> bool:
    return bool(value) and value not in {".", ".."} and "/" not in value and "\\" not in value \
        and all(ord(character) >= 32 and ord(character) != 127 for character in value)


def _validated_manifest(package: Path, key: bytes) -> dict[str, Any]:
    manifest_path = package / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise LocalDeviceTransferError("Local Device backup manifest is missing")
    if manifest_path.stat().st_size > MAXIMUM_MANIFEST_BYTES:
        raise LocalDeviceTransferError("Local Device backup manifest is too large")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as failure:
        raise LocalDeviceTransferError("Local Device backup manifest is invalid") from failure
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT \
            or manifest.get("version") != FORMAT_VERSION \
            or not isinstance(manifest.get("budget_id"), str) or not manifest["budget_id"] \
            or not isinstance(manifest.get("local_schema_version"), int) \
            or not 1 <= manifest["local_schema_version"] <= LOCAL_SCHEMA_VERSION:
        raise LocalDeviceTransferError("Local Device backup format or schema is unsupported")
    authentication = manifest.get("authentication")
    if not isinstance(authentication, str) or len(authentication) != 64:
        raise LocalDeviceTransferError("Local Device backup authentication is invalid")
    unsigned = dict(manifest)
    unsigned["authentication"] = ""
    expected = hmac.new(key, canonical_json(unsigned), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(authentication.lower(), expected):
        raise LocalDeviceTransferError("Local Device backup manifest failed authentication")
    files = manifest.get("files")
    if not isinstance(files, list) or not 2 <= len(files) <= MAXIMUM_FILES:
        raise LocalDeviceTransferError("Local Device backup file manifest is incomplete")
    payload_names: set[str] = set()
    restore_paths: set[str] = set()
    roles: list[str] = []
    for item in files:
        if not isinstance(item, dict):
            raise LocalDeviceTransferError("Local Device backup file record is invalid")
        payload_name, restore_path, role = (
            item.get("payload_name"), item.get("restore_path"), item.get("role")
        )
        if not isinstance(payload_name, str) or not _safe_component(payload_name) \
                or not payload_name.endswith(".cpenc") or payload_name in payload_names:
            raise LocalDeviceTransferError("Local Device backup payload name is unsafe or duplicated")
        if not isinstance(restore_path, str) or restore_path in restore_paths:
            raise LocalDeviceTransferError("Local Device backup restore path is unsafe or duplicated")
        path = PurePosixPath(restore_path)
        if path.is_absolute() or ".." in path.parts or str(path) != restore_path \
                or not all(_safe_component(part) for part in path.parts):
            raise LocalDeviceTransferError("Local Device backup restore path is unsafe or duplicated")
        allowed = (
            (role == "database" and restore_path == "authority.sqlite3")
            or (role == "attachment_key" and restore_path == "attachment-key.bin")
            or (role == "attachment_object" and restore_path.startswith("Attachments/objects/"))
            or (role == "attachment_tombstone" and restore_path.startswith("Attachments/tombstones/"))
        )
        if not allowed:
            raise LocalDeviceTransferError("Local Device backup role and restore path disagree")
        for field in ("plaintext_bytes", "encrypted_bytes"):
            if not isinstance(item.get(field), int) or item[field] < (1 if field == "encrypted_bytes" else 0):
                raise LocalDeviceTransferError("Local Device backup file size is invalid")
        for field in ("plaintext_sha256", "encrypted_sha256"):
            digest = item.get(field)
            if not isinstance(digest, str) or len(digest) != 64:
                raise LocalDeviceTransferError("Local Device backup file hash is invalid")
        payload_names.add(payload_name); restore_paths.add(restore_path); roles.append(str(role))
    if roles.count("database") != 1 or roles.count("attachment_key") != 1:
        raise LocalDeviceTransferError("Local Device backup must contain one database and attachment key")
    payload_root = package / "payload"
    if payload_root.is_symlink() or not payload_root.is_dir():
        raise LocalDeviceTransferError("Local Device backup payload directory is missing")
    actual = {item.name for item in payload_root.iterdir() if item.is_file() and not item.is_symlink()}
    if actual != payload_names or any(item.is_symlink() or not item.is_file() for item in payload_root.iterdir()):
        raise LocalDeviceTransferError("Local Device backup payload coverage is incomplete")
    return manifest


def _decrypt_payload(source: Path, destination: Path, item: dict[str, Any], key: bytes) -> None:
    encrypted_hash = hashlib.sha256()
    plaintext_hash = hashlib.sha256()
    encrypted_bytes = 0
    plaintext_bytes = 0
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with source.open("rb") as incoming, destination.open("xb") as output:
            magic = incoming.read(len(MAGIC))
            if magic != MAGIC:
                raise LocalDeviceTransferError("Local Device encrypted payload format is invalid")
            encrypted_hash.update(magic); encrypted_bytes += len(magic)
            cipher = AESGCM(key)
            while True:
                length_data = incoming.read(4)
                if len(length_data) != 4:
                    raise LocalDeviceTransferError("Local Device encrypted payload is truncated")
                encrypted_hash.update(length_data); encrypted_bytes += 4
                length = struct.unpack(">I", length_data)[0]
                if length == 0:
                    break
                if length > MAXIMUM_CHUNK_BYTES:
                    raise LocalDeviceTransferError("Local Device encrypted payload chunk is too large")
                combined = incoming.read(length)
                if len(combined) != length:
                    raise LocalDeviceTransferError("Local Device encrypted payload is truncated")
                encrypted_hash.update(combined); encrypted_bytes += len(combined)
                try:
                    plaintext = cipher.decrypt(combined[:12], combined[12:], None)
                except Exception as failure:
                    raise LocalDeviceTransferError(
                        "Local Device encrypted payload failed authentication"
                    ) from failure
                output.write(plaintext); plaintext_hash.update(plaintext)
                plaintext_bytes += len(plaintext)
            if incoming.read(1):
                raise LocalDeviceTransferError("Local Device encrypted payload contains trailing data")
            output.flush(); os.fsync(output.fileno())
        if plaintext_bytes != item["plaintext_bytes"] or encrypted_bytes != item["encrypted_bytes"] \
                or not hmac.compare_digest(plaintext_hash.hexdigest(), item["plaintext_sha256"].lower()) \
                or not hmac.compare_digest(encrypted_hash.hexdigest(), item["encrypted_sha256"].lower()):
            raise LocalDeviceTransferError("Local Device encrypted payload integrity does not match")
        os.chmod(destination, 0o600)
    except Exception:
        destination.unlink(missing_ok=True)
        raise


def stage_local_device_backup(package: Path, destination: Path, recovery_key: str) -> dict[str, Any]:
    package = package.expanduser()
    if package.is_symlink() or not package.is_dir():
        raise LocalDeviceTransferError("Local Device backup package was not found")
    package = package.resolve()
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise LocalDeviceTransferError("Local Device transfer staging destination already exists")
    key = decode_recovery_key(recovery_key)
    manifest = _validated_manifest(package, key)
    temporary = destination.with_name(f".{destination.name}.staging-{os.getpid()}")
    if temporary.exists():
        raise LocalDeviceTransferError("Local Device transfer staging path already exists")
    temporary.mkdir(mode=0o700, parents=True)
    published = False
    try:
        for item in manifest["files"]:
            _decrypt_payload(
                package / "payload" / item["payload_name"],
                temporary / item["restore_path"], item, key,
            )
        attachment_key = (temporary / "attachment-key.bin").read_bytes()
        if len(attachment_key) != 32:
            raise LocalDeviceTransferError("Local Device attachment key is invalid")
        database = temporary / "authority.sqlite3"
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
            if connection.execute("PRAGMA application_id").fetchone() != (LOCAL_APPLICATION_ID,):
                raise LocalDeviceTransferError("Local Device database identity is invalid")
            if connection.execute("PRAGMA user_version").fetchone()[0] > LOCAL_SCHEMA_VERSION:
                raise LocalDeviceTransferError("Local Device database schema is newer than this server")
            if connection.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                raise LocalDeviceTransferError("Local Device database integrity check failed")
            if connection.execute("PRAGMA foreign_key_check").fetchall():
                raise LocalDeviceTransferError("Local Device database has foreign-key violations")
            budget = connection.execute("SELECT id FROM budgets").fetchall()
            if budget != [(manifest["budget_id"],)]:
                raise LocalDeviceTransferError("Local Device database budget does not match its manifest")
        os.rename(temporary, destination)
        published = True
        return manifest
    finally:
        if not published:
            shutil.rmtree(temporary, ignore_errors=True)


def staged_inventory(root: Path) -> dict[str, int]:
    database = root / "authority.sqlite3"
    tables = [
        "accounts", "category_groups", "categories", "payees", "transactions",
        "transaction_splits", "allocation_operations", "reconciliations",
        "category_targets", "scheduled_transactions", "attachments",
    ]
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        existing = {
            row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        return {
            table: int(connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
            for table in tables if table in existing
        }


def _record_server_import(status: Path, manifest: dict[str, Any]) -> None:
    if status.is_symlink():
        raise LocalDeviceTransferError("Server recovery status path must not be a symbolic link")
    status.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload: dict[str, object] = {
        "state": "verified", "verified_at": datetime.now().astimezone().isoformat(),
        "source_provider": "local_device_backup",
        "source_archive_sha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
        "database_integrity": "ok", "foreign_keys": "ok",
    }
    temporary = status.with_name(f".{status.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, status)


def import_local_device_backup_into_server(
    package: Path, recovery_key: str, owner_email: str, owner_password: str,
) -> dict[str, Any]:
    """Authenticate, convert, and atomically initialize one empty configured server authority."""
    required = {
        "BUDGET_APP_DATABASE_URL", "BUDGET_APP_JWT_SECRET",
        "BUDGET_APP_ATTACHMENT_STORAGE_PATH", "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY",
        "BUDGET_APP_RECOVERY_STATUS_PATH",
    }
    missing = sorted(key for key in required if not os.environ.get(key, "").strip())
    if missing:
        raise LocalDeviceTransferError(
            "Server import configuration is incomplete: " + ", ".join(missing)
        )
    from app.database import build_session_factory
    from scripts.local_device_payload import convert_staged_local_device
    from scripts.portable_import import (
        _financial_observations_from_database, _financial_observations_from_payload,
        import_payload_into_authority,
    )

    package = package.expanduser().resolve()
    with tempfile.TemporaryDirectory(prefix=".clearpocket-local-device-import-") as name:
        staged = Path(name) / "verified"
        manifest = stage_local_device_backup(package, staged, recovery_key)
        payload, extracted = convert_staged_local_device(staged, owner_email)
        import_payload_into_authority(
            payload, extracted,
            database_url=os.environ["BUDGET_APP_DATABASE_URL"],
            attachment_path=Path(os.environ["BUDGET_APP_ATTACHMENT_STORAGE_PATH"]).resolve(),
            deployment_secret=os.environ["BUDGET_APP_JWT_SECRET"],
            attachment_encryption_key=os.environ["BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"],
            owner_password=owner_password,
        )
        engine = build_session_factory(os.environ["BUDGET_APP_DATABASE_URL"]).kw["bind"]
        if _financial_observations_from_payload(payload) != _financial_observations_from_database(engine):
            raise LocalDeviceTransferError("Local Device financial observations changed after server import")
        _record_server_import(Path(os.environ["BUDGET_APP_RECOVERY_STATUS_PATH"]).resolve(), manifest)
        return manifest


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument(
        "--server-environment", action="store_true",
        help="initialize the new empty authority configured by BUDGET_APP_* variables",
    )
    args = parser.parse_args(arguments)
    try:
        recovery_key = getpass.getpass("Local Device backup recovery key: ")
        if args.server_environment:
            owner_email = input("New server owner email: ").strip()
            password = getpass.getpass("New server owner password: ")
            confirmation = getpass.getpass("Confirm new server owner password: ")
            if password != confirmation:
                raise LocalDeviceTransferError("Owner password confirmation does not match")
            manifest = import_local_device_backup_into_server(
                args.package, recovery_key, owner_email, password
            )
            print(f"Local Device budget imported into the new empty server: {manifest['budget_id']}")
            return 0
        with tempfile.TemporaryDirectory(prefix=".clearpocket-local-device-verify-") as name:
            destination = Path(name) / "verified"
            manifest = stage_local_device_backup(args.package, destination, recovery_key)
            inventory = staged_inventory(destination)
        summary = " ".join(f"{name}={count}" for name, count in sorted(inventory.items()))
        print(f"Local Device backup verified: budget={manifest['budget_id']} {summary}")
        print("No server authority was created or modified.")
        return 0
    except (OSError, RuntimeError, sqlite3.Error) as failure:
        print(f"Local Device backup verification error: {failure}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
