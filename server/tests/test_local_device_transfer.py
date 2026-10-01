from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
from pathlib import Path
import sqlite3
import struct

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import pytest
import scripts.local_device_transfer as transfer

from scripts.local_device_transfer import (
    canonical_json, LocalDeviceTransferError, LOCAL_APPLICATION_ID,
    stage_local_device_backup, staged_inventory,
)


def _encrypted_payload(plaintext: bytes, key: bytes) -> tuple[bytes, dict[str, object]]:
    cipher = AESGCM(key)
    output = bytearray(b"CPBF1")
    for offset in range(0, len(plaintext), 1_048_576):
        chunk = plaintext[offset:offset + 1_048_576]
        nonce = bytes((offset // 1_048_576 + value) % 256 for value in range(12))
        combined = nonce + cipher.encrypt(nonce, chunk, None)
        output += struct.pack(">I", len(combined)) + combined
    output += struct.pack(">I", 0)
    payload = bytes(output)
    return payload, {
        "plaintext_bytes": len(plaintext),
        "plaintext_sha256": hashlib.sha256(plaintext).hexdigest(),
        "encrypted_bytes": len(payload),
        "encrypted_sha256": hashlib.sha256(payload).hexdigest(),
    }


def _local_database(path: Path) -> bytes:
    with sqlite3.connect(path) as database:
        database.executescript(f"""
            PRAGMA application_id={LOCAL_APPLICATION_ID};
            PRAGMA user_version=3;
            PRAGMA foreign_keys=ON;
            CREATE TABLE households(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE budgets(id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id), name TEXT NOT NULL);
            CREATE TABLE accounts(id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id));
            CREATE TABLE transactions(id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id));
            INSERT INTO households VALUES('household','Phone household','2026-10-01T00:00:00Z');
            INSERT INTO budgets VALUES('budget','household','Phone budget');
        """)
    return path.read_bytes()


def _package(root: Path, key: bytes) -> Path:
    package = root / "phone.clearpocketbackup"
    payload_root = package / "payload"
    payload_root.mkdir(parents=True)
    database = _local_database(root / "source.sqlite3")
    values = [
        ("000000.cpenc", "authority.sqlite3", "database", database),
        ("000001.cpenc", "attachment-key.bin", "attachment_key", bytes(range(32))),
        ("000002.cpenc", "Attachments/objects/receipt.enc", "attachment_object", b"BAV1ciphertext"),
    ]
    files = []
    for payload_name, restore_path, role, plaintext in values:
        encrypted, observation = _encrypted_payload(plaintext, key)
        (payload_root / payload_name).write_bytes(encrypted)
        files.append({
            "payload_name": payload_name, "restore_path": restore_path, "role": role,
            **observation,
        })
    manifest = {
        "format": "com.clearpocket.local-backup", "version": 1,
        "created_at": "2026-10-01T00:00:00Z", "local_schema_version": 3,
        "budget_id": "budget", "files": files, "authentication": "",
    }
    manifest["authentication"] = hmac.new(key, canonical_json(manifest), hashlib.sha256).hexdigest()
    (package / "manifest.json").write_bytes(canonical_json(manifest))
    return package


def _encoded(key: bytes) -> str:
    return base64.urlsafe_b64encode(key).decode().rstrip("=")


def test_manifest_canonicalization_matches_foundation_slash_encoding():
    assert canonical_json({"authentication": "", "restore_path": "Attachments/objects/x"}) == (
        b'{"authentication":"","restore_path":"Attachments\\/objects\\/x"}'
    )


def test_local_device_backup_stages_authenticated_database_key_and_objects(tmp_path: Path):
    key = bytes(reversed(range(32)))
    package = _package(tmp_path, key)
    destination = tmp_path / "verified"
    manifest = stage_local_device_backup(package, destination, _encoded(key))
    assert manifest["budget_id"] == "budget"
    assert (destination / "authority.sqlite3").is_file()
    assert (destination / "attachment-key.bin").read_bytes() == bytes(range(32))
    assert (destination / "Attachments" / "objects" / "receipt.enc").read_bytes() == b"BAV1ciphertext"
    with sqlite3.connect(destination / "authority.sqlite3") as database:
        assert database.execute("SELECT name FROM budgets").fetchone() == ("Phone budget",)
    assert staged_inventory(destination)["accounts"] == 0
    assert staged_inventory(destination)["transactions"] == 0


def test_local_device_backup_wrong_key_or_payload_tampering_never_publishes(tmp_path: Path):
    key = bytes(range(32))
    package = _package(tmp_path, key)
    with pytest.raises(LocalDeviceTransferError, match="authentication"):
        stage_local_device_backup(package, tmp_path / "wrong", _encoded(bytes(reversed(key))))
    assert not (tmp_path / "wrong").exists()

    payload = package / "payload" / "000000.cpenc"
    damaged = bytearray(payload.read_bytes()); damaged[-5] ^= 1; payload.write_bytes(damaged)
    with pytest.raises(LocalDeviceTransferError, match="authentication|integrity"):
        stage_local_device_backup(package, tmp_path / "damaged", _encoded(key))
    assert not (tmp_path / "damaged").exists()


def test_authenticated_local_device_manifest_still_rejects_unsafe_restore_path(tmp_path: Path):
    key = bytes(range(32))
    package = _package(tmp_path, key)
    manifest = json.loads((package / "manifest.json").read_text())
    manifest["files"][0]["restore_path"] = "../authority.sqlite3"
    manifest["authentication"] = ""
    manifest["authentication"] = hmac.new(key, canonical_json(manifest), hashlib.sha256).hexdigest()
    (package / "manifest.json").write_bytes(canonical_json(manifest))
    with pytest.raises(LocalDeviceTransferError, match="restore path"):
        stage_local_device_backup(package, tmp_path / "unsafe", _encoded(key))
    assert not (tmp_path / "unsafe").exists()


def test_server_import_accepts_private_credentials_on_stdin_without_echo(monkeypatch, tmp_path, capsys):
    captured = {}

    def fake_import(package, recovery_key, owner_email, owner_password):
        captured.update(
            package=package, recovery_key=recovery_key,
            owner_email=owner_email, owner_password=owner_password,
        )
        return {"budget_id": "budget"}

    monkeypatch.setattr(transfer, "import_local_device_backup_into_server", fake_import)
    monkeypatch.setattr(
        transfer.sys, "stdin",
        io.StringIO("private-recovery\nowner@example.com\nprivate-password\nprivate-password\n"),
    )
    package = tmp_path / "phone.clearpocketbackup"
    assert transfer.main([
        str(package), "--server-environment", "--server-credentials-stdin",
    ]) == 0
    assert captured == {
        "package": package,
        "recovery_key": "private-recovery",
        "owner_email": "owner@example.com",
        "owner_password": "private-password",
    }
    output = capsys.readouterr()
    assert "private-recovery" not in output.out + output.err
    assert "private-password" not in output.out + output.err


def test_private_stdin_mode_requires_complete_matching_credentials(monkeypatch, tmp_path):
    monkeypatch.setattr(transfer.sys, "stdin", io.StringIO("key\nowner@example.com\none\ntwo\n"))
    assert transfer.main([
        str(tmp_path / "phone.clearpocketbackup"),
        "--server-environment", "--server-credentials-stdin",
    ]) == 1
