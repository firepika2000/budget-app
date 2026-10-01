#!/usr/bin/env python3
"""Atomically record sanitized operational backup health inside the configured volume."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat


class BackupHealthError(RuntimeError):
    pass


def _digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def record(state: str, archive: Path | None = None, reported_path: str | None = None) -> dict[str, object]:
    configured = os.environ.get("BUDGET_APP_BACKUP_STATUS_PATH", "").strip()
    if not configured:
        raise BackupHealthError("Backup health path is not configured")
    target = Path(configured)
    if target.is_symlink():
        raise BackupHealthError("Backup health path must not be a symbolic link")
    if state not in {"healthy", "failed"}:
        raise BackupHealthError("Backup health state is invalid")
    payload: dict[str, object] = {
        "state": state,
        "completed_at": datetime.now(timezone.utc).isoformat(),
    }
    if state == "healthy":
        if archive is None or archive.is_symlink() or not archive.is_file():
            raise BackupHealthError("A healthy backup requires a regular encrypted generation")
        metadata = archive.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise BackupHealthError("Backup generation must be a regular file")
        display = reported_path or archive.name
        if not display or any(character in display for character in "\r\n\0") or len(display) > 4096:
            raise BackupHealthError("Reported backup path is invalid")
        payload.update({
            "archive": display,
            "size": metadata.st_size,
            "sha256": _digest(archive),
            "destination": {"destination": "local_generation", "path": display},
        })
    else:
        payload["error"] = "Backup capture failed"

    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            json.dump(payload, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
        directory = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state", choices=("healthy", "failed"))
    parser.add_argument("archive", type=Path, nargs="?")
    parser.add_argument("--reported-path")
    arguments = parser.parse_args()
    try:
        payload = record(arguments.state, arguments.archive, arguments.reported_path)
    except (BackupHealthError, OSError) as failure:
        parser.exit(1, f"Backup health error: {failure}\n")
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
