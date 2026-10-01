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


def _dropbox_destination(value: object, *, archive: Path, digest: str) -> dict[str, object]:
    if not isinstance(value, dict) or value.get("destination") != "dropbox":
        raise BackupHealthError("Backup destination metadata is invalid")
    path = value.get("path")
    filename = value.get("filename")
    size = value.get("size")
    content_hash = value.get("content_hash")
    remote_digest = value.get("sha256")
    verified_at = value.get("verified_at")
    if not isinstance(path, str) or not path.startswith("/") or len(path) > 4096 or any(
        character in path for character in "\r\n\0"
    ):
        raise BackupHealthError("Backup destination path is invalid")
    if filename != archive.name or path.rsplit("/", 1)[-1] != filename:
        raise BackupHealthError("Backup destination filename is invalid")
    if not isinstance(size, int) or isinstance(size, bool) or size != archive.stat().st_size:
        raise BackupHealthError("Backup destination size is invalid")
    if not isinstance(content_hash, str) or len(content_hash) != 64 or any(
        character not in "0123456789abcdef" for character in content_hash
    ):
        raise BackupHealthError("Backup destination content hash is invalid")
    if remote_digest != digest:
        raise BackupHealthError("Backup destination digest does not match the local generation")
    if not isinstance(verified_at, int) or isinstance(verified_at, bool) or verified_at < 1:
        raise BackupHealthError("Backup destination verification time is invalid")
    return {
        "destination": "dropbox",
        "path": path,
        "filename": filename,
        "size": size,
        "content_hash": content_hash,
        "sha256": remote_digest,
        "verified_at": verified_at,
    }


def _digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def record(state: str, archive: Path | None = None, reported_path: str | None = None,
           destination: object | None = None) -> dict[str, object]:
    configured = os.environ.get("BUDGET_APP_BACKUP_STATUS_PATH", "").strip()
    if not configured:
        raise BackupHealthError("Backup health path is not configured")
    target = Path(configured)
    if target.is_symlink():
        raise BackupHealthError("Backup health path must not be a symbolic link")
    if state not in {"healthy", "failed", "publication_failed"}:
        raise BackupHealthError("Backup health state is invalid")
    payload: dict[str, object] = {
        "state": state,
        "completed_at": datetime.now(timezone.utc).isoformat(),
    }
    if state in {"healthy", "publication_failed"}:
        if archive is None or archive.is_symlink() or not archive.is_file():
            raise BackupHealthError("A healthy backup requires a regular encrypted generation")
        metadata = archive.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise BackupHealthError("Backup generation must be a regular file")
        display = reported_path or archive.name
        if not display or any(character in display for character in "\r\n\0") or len(display) > 4096:
            raise BackupHealthError("Reported backup path is invalid")
        digest = _digest(archive)
        payload.update({
            "archive": display,
            "size": metadata.st_size,
            "sha256": digest,
            "destination": _dropbox_destination(destination, archive=archive, digest=digest)
                if destination is not None
                else {"destination": "local_generation", "path": display},
        })
        if state == "publication_failed":
            if destination is not None:
                raise BackupHealthError("Failed publication cannot claim a remote destination")
            payload["error"] = "Off-device backup publication failed"
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
    parser.add_argument("--destination-json", type=Path)
    arguments = parser.parse_args()
    try:
        destination = None
        if arguments.destination_json is not None:
            if arguments.destination_json.is_symlink() or not arguments.destination_json.is_file():
                raise BackupHealthError("Backup destination metadata file is invalid")
            if arguments.destination_json.stat().st_size > 16 * 1024:
                raise BackupHealthError("Backup destination metadata file is too large")
            destination = json.loads(arguments.destination_json.read_text(encoding="utf-8"))
        payload = record(arguments.state, arguments.archive, arguments.reported_path, destination)
    except (BackupHealthError, OSError, UnicodeError, json.JSONDecodeError) as failure:
        parser.exit(1, f"Backup health error: {failure}\n")
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
