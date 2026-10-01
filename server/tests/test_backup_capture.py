from __future__ import annotations

import base64
import hashlib
from pathlib import Path
import sqlite3
from types import SimpleNamespace

import pytest

from app.attachment_storage import AttachmentStorage
from app.config import Settings
from scripts.backup_capture import (
    BackupCaptureError, validate_attachment_capture, validate_attachment_rows,
)


def capture_storage(tmp_path: Path) -> AttachmentStorage:
    key = base64.urlsafe_b64encode(bytes(range(32))).decode()
    return AttachmentStorage(str(tmp_path / "attachments"), "deployment-secret", key)


def observation(key: str, content: bytes):
    return SimpleNamespace(
        storage_key=key,
        byte_count=len(content),
        sha256=hashlib.sha256(content).hexdigest(),
    )


def test_frozen_attachment_capture_authenticates_every_database_object(tmp_path: Path):
    storage = capture_storage(tmp_path)
    first = b"\x89PNG\r\n\x1a\nfirst receipt"
    second = b"%PDF-1.7 second receipt"
    storage.write("first-object", first)
    storage.write("detached-tombstone", second)

    assert validate_attachment_rows([
        observation("first-object", first),
        observation("detached-tombstone", second),
    ], storage) == 2


def test_frozen_attachment_capture_reads_authoritative_database_rows(tmp_path: Path):
    storage = capture_storage(tmp_path)
    content = b"%PDF-1.7 authoritative receipt"
    storage.write("database-object", content)
    database = tmp_path / "authority.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute("""
            CREATE TABLE transaction_attachments (
                id TEXT PRIMARY KEY, budget_id TEXT NOT NULL, transaction_id TEXT NOT NULL,
                filename TEXT NOT NULL, content_type TEXT NOT NULL, byte_count BIGINT NOT NULL,
                sha256 TEXT NOT NULL, storage_key TEXT NOT NULL UNIQUE,
                created_by_user_id TEXT NOT NULL, created_at DATETIME NOT NULL,
                detached_at DATETIME, detached_by_user_id TEXT, purge_after DATETIME
            )
        """)
        connection.execute(
            "INSERT INTO transaction_attachments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "attachment-id", "budget-id", "transaction-id", "receipt.pdf",
                "application/pdf", len(content), hashlib.sha256(content).hexdigest(),
                "database-object", "owner-id", "2026-10-01 00:00:00",
                None, None, None,
            ),
        )
    key = base64.urlsafe_b64encode(bytes(range(32))).decode()
    settings = Settings(
        database_url=f"sqlite:///{database}", jwt_secret="x" * 32,
        attachment_storage_path=str(storage.root), attachment_encryption_key=key,
    )

    assert validate_attachment_capture(storage.root, settings) == 1


@pytest.mark.parametrize("failure", ["missing", "corrupt", "wrong-size", "wrong-digest"])
def test_frozen_attachment_capture_rejects_database_object_mismatch(
    tmp_path: Path, failure: str
):
    storage = capture_storage(tmp_path)
    content = b"\x89PNG\r\n\x1a\nreceipt"
    row = observation("attachment-object", content)
    if failure != "missing":
        storage.write(row.storage_key, content)
    if failure == "corrupt":
        (storage.root / row.storage_key).write_bytes(b"not authenticated ciphertext")
    elif failure == "wrong-size":
        row.byte_count += 1
    elif failure == "wrong-digest":
        row.sha256 = "0" * 64

    with pytest.raises(BackupCaptureError):
        validate_attachment_rows([row], storage)


def test_frozen_attachment_capture_rejects_unsafe_storage_key(tmp_path: Path):
    storage = capture_storage(tmp_path)
    with pytest.raises(BackupCaptureError, match="unsafe storage key"):
        validate_attachment_rows([
            observation("../outside-object", b"not read"),
        ], storage)
