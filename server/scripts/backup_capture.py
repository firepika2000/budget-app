#!/usr/bin/env python3
"""Validate a frozen database-plus-attachment backup capture before serving resumes."""
from __future__ import annotations

import argparse
import hashlib
import hmac
import os
from pathlib import Path
import stat
from typing import Iterable, Protocol

from cryptography.exceptions import InvalidTag
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError

from app.attachment_storage import AttachmentStorage
from app.config import Settings
from app.database import build_session_factory
from app.models import TransactionAttachment


class AttachmentObservation(Protocol):
    storage_key: str
    byte_count: int
    sha256: str


class BackupCaptureError(RuntimeError):
    pass


def validate_attachment_rows(
    rows: Iterable[AttachmentObservation], storage: AttachmentStorage
) -> int:
    count = 0
    for row in rows:
        key = row.storage_key
        if (not key or len(key) > 100 or Path(key).name != key
                or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
                       for character in key)):
            raise BackupCaptureError("Attachment metadata contains an unsafe storage key")
        path = storage.root / key
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError as error:
            raise BackupCaptureError("A database attachment object is missing from the capture") from error
        if not stat.S_ISREG(mode) or path.is_symlink():
            raise BackupCaptureError("A captured attachment object is not a regular file")
        try:
            content = storage.read(key)
        except (OSError, ValueError, InvalidTag) as error:
            raise BackupCaptureError("A captured attachment object could not be authenticated") from error
        if len(content) != row.byte_count:
            raise BackupCaptureError("A captured attachment byte count does not match the database")
        observed = hashlib.sha256(content).hexdigest()
        if not hmac.compare_digest(observed, row.sha256):
            raise BackupCaptureError("A captured attachment digest does not match the database")
        count += 1
    return count


def validate_attachment_capture(root: Path, settings: Settings | None = None) -> int:
    settings = settings or Settings.from_environment()
    if root.is_symlink() or not root.is_dir():
        raise BackupCaptureError("Attachment capture must be a regular directory")
    storage = AttachmentStorage(
        str(root), settings.jwt_secret, settings.attachment_encryption_key
    )
    factory = build_session_factory(settings.database_url)
    with factory() as session:
        rows = session.scalars(
            select(TransactionAttachment).order_by(TransactionAttachment.id)
        )
        return validate_attachment_rows(rows, storage)


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["validate-attachments"])
    parser.add_argument("capture", type=Path)
    args = parser.parse_args(arguments)
    try:
        count = validate_attachment_capture(args.capture)
        print(f"Validated {count} database attachment object(s) in the frozen capture")
        return 0
    except SQLAlchemyError:
        parser.exit(1, "Backup capture validation failed: database validation is unavailable\n")
    except (BackupCaptureError, OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"Backup capture validation failed: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
