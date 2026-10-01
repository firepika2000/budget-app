from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from scripts.backup_health import BackupHealthError, record


def test_backup_health_atomically_records_only_sanitized_generation_metadata(tmp_path: Path, monkeypatch):
    status = tmp_path / "operations" / "backup-status.json"
    archive = tmp_path / "generation.age"
    archive.write_bytes(b"encrypted generation")
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(status))

    payload = record("healthy", archive, "/share/Private/Backups/generation.age")

    assert json.loads(status.read_text()) == payload
    assert payload["state"] == "healthy"
    assert payload["size"] == len(b"encrypted generation")
    assert len(payload["sha256"]) == 64
    assert payload["destination"] == {
        "destination": "local_generation", "path": "/share/Private/Backups/generation.age",
    }
    assert status.stat().st_mode & 0o777 == 0o600
    assert not list(status.parent.glob("*.tmp"))


def test_backup_health_failure_never_records_secrets_or_untrusted_details(tmp_path: Path, monkeypatch):
    status = tmp_path / "backup-status.json"
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(status))
    payload = record("failed")
    assert json.loads(status.read_text()) == payload
    assert payload["error"] == "Backup capture failed"
    assert "archive" not in payload


def test_backup_health_records_verified_dropbox_publication_without_credentials(tmp_path: Path, monkeypatch):
    status = tmp_path / "backup-status.json"
    archive = tmp_path / "budget-20261001T030000Z.tar.gz.age"
    archive.write_bytes(b"encrypted generation")
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(status))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    destination = {
        "destination": "dropbox",
        "path": f"/Backups/{archive.name}",
        "filename": archive.name,
        "size": archive.stat().st_size,
        "content_hash": "a" * 64,
        "sha256": digest,
        "verified_at": 1790823600,
        "removed_generations": ["older.age"],
        "credential": "must-not-survive",
    }

    payload = record("healthy", archive, str(archive), destination)

    assert payload["destination"] == {key: destination[key] for key in (
        "destination", "path", "filename", "size", "content_hash", "sha256", "verified_at"
    )}
    assert "credential" not in json.dumps(payload)
    destination["sha256"] = "0" * 64
    with pytest.raises(BackupHealthError, match="digest"):
        record("healthy", archive, str(archive), destination)


def test_backup_health_distinguishes_retained_local_generation_after_publication_failure(
    tmp_path: Path, monkeypatch
):
    status = tmp_path / "backup-status.json"
    archive = tmp_path / "budget-20261001T030000Z.tar.gz.age"
    archive.write_bytes(b"encrypted generation")
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(status))

    payload = record("publication_failed", archive, str(archive))

    assert payload["state"] == "publication_failed"
    assert payload["archive"] == str(archive)
    assert payload["destination"]["destination"] == "local_generation"
    assert payload["error"] == "Off-device backup publication failed"


def test_backup_health_refuses_links_missing_archives_and_unsafe_reported_paths(tmp_path: Path, monkeypatch):
    status = tmp_path / "backup-status.json"
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(status))
    archive = tmp_path / "generation.age"
    archive.write_bytes(b"encrypted")
    link = tmp_path / "linked.age"
    link.symlink_to(archive)
    with pytest.raises(BackupHealthError, match="regular encrypted"):
        record("healthy", link)
    with pytest.raises(BackupHealthError, match="regular encrypted"):
        record("healthy", tmp_path / "missing.age")
    with pytest.raises(BackupHealthError, match="Reported backup path"):
        record("healthy", archive, "bad\npath")
    assert not status.exists()


def test_backup_health_refuses_unconfigured_or_linked_status_path(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("BUDGET_APP_BACKUP_STATUS_PATH", raising=False)
    with pytest.raises(BackupHealthError, match="not configured"):
        record("failed")
    real = tmp_path / "real.json"
    real.write_text("{}")
    linked = tmp_path / "backup-status.json"
    linked.symlink_to(real)
    monkeypatch.setenv("BUDGET_APP_BACKUP_STATUS_PATH", str(linked))
    with pytest.raises(BackupHealthError, match="symbolic link"):
        record("failed")
    assert real.read_text() == "{}"
