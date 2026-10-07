from __future__ import annotations

import base64
import os
from pathlib import Path
import sqlite3

import pytest

from scripts.local_server import (
    LocalServerConfiguration, LocalServerError, backup_local, backup_status, exclusive_server_lock,
    migrate, migration_state, restore_local, run,
)


SERVER_ROOT = Path(__file__).parents[1]


def test_local_configuration_is_private_stable_and_uses_self_contained_paths(tmp_path):
    configuration = LocalServerConfiguration.load_or_create(tmp_path / "local")
    reloaded = LocalServerConfiguration.load_or_create(tmp_path / "local")

    assert reloaded == configuration
    assert len(configuration.jwt_secret) >= 32
    assert len(base64.urlsafe_b64decode(configuration.attachment_encryption_key)) == 32
    assert configuration.config_path.stat().st_mode & 0o777 == 0o600
    assert configuration.data_directory.stat().st_mode & 0o777 == 0o700
    assert configuration.attachment_path.stat().st_mode & 0o777 == 0o700
    environment = configuration.environment()
    assert environment["BUDGET_APP_DATABASE_URL"] == f"sqlite:///{configuration.database_path}"
    assert environment["BUDGET_APP_ATTACHMENT_STORAGE_PATH"] == str(configuration.attachment_path)


def test_local_configuration_never_replaces_invalid_or_future_state(tmp_path):
    directory = tmp_path / "local"
    directory.mkdir()
    path = directory / "configuration.json"
    path.write_text('{"format_version":99}')
    before = path.read_bytes()
    with pytest.raises(LocalServerError, match="unsupported"):
        LocalServerConfiguration.load_or_create(directory)
    assert path.read_bytes() == before


def test_local_server_lock_prevents_two_writers(tmp_path):
    configuration = LocalServerConfiguration.load_or_create(tmp_path / "local")
    with exclusive_server_lock(configuration):
        with pytest.raises(LocalServerError, match="already in use"):
            with exclusive_server_lock(configuration):
                pass


def test_non_loopback_binding_requires_explicit_allowed_hosts(tmp_path):
    configuration = LocalServerConfiguration.load_or_create(tmp_path / "local")
    with pytest.raises(LocalServerError, match="explicit --allowed-hosts"):
        run(configuration, SERVER_ROOT, "0.0.0.0", 8000, "localhost,127.0.0.1")


def test_local_mode_runs_full_migration_graph_and_preserves_populated_database(tmp_path):
    configuration = LocalServerConfiguration.load_or_create(tmp_path / "local")
    migrate(configuration, SERVER_ROOT)
    assert "0034_schedule_end_date (head)" in migration_state(configuration, SERVER_ROOT)
    with sqlite3.connect(configuration.database_path) as database:
        database.execute("INSERT INTO users(id,email,password_hash,display_name,created_at) VALUES (?,?,?,?,?)",
                         ("owner", "owner@example.test", "hash", "Owner", "2026-09-27 00:00:00"))
        database.commit()

    migrate(configuration, SERVER_ROOT)
    with sqlite3.connect(configuration.database_path) as database:
        assert database.execute("SELECT display_name FROM users WHERE id='owner'").fetchone() == ("Owner",)


def test_local_backup_restore_preserves_database_attachments_and_key_in_new_authority(tmp_path, monkeypatch):
    tools = tmp_path / "tools"
    tools.mkdir()
    age = tools / "age"
    age.write_text(
        """#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then output="$2"; shift 2
  elif [[ "$1" == "--recipient" || "$1" == "--identity" ]]; then shift 2
  elif [[ "$1" == "--passphrase" || "$1" == "--decrypt" ]]; then shift
  else input="$1"; shift
  fi
done
cp "$input" "$output"
"""
    )
    age.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}:{os.environ['PATH']}")
    monkeypatch.setenv("BUDGET_APP_BACKUP_AGE_RECIPIENT", "age1test")

    source = LocalServerConfiguration.load_or_create(tmp_path / "source")
    migrate(source, SERVER_ROOT)
    with sqlite3.connect(source.database_path) as database:
        database.execute("INSERT INTO users(id,email,password_hash,display_name,created_at) VALUES (?,?,?,?,?)",
                         ("owner", "owner@example.test", "hash", "Owner", "2026-09-27 00:00:00"))
        database.execute(
            "INSERT INTO refresh_sessions(id,user_id,token_hash,expires_at,created_at,revoked_at) VALUES (?,?,?,?,?,?)",
            ("session", "owner", "hash", "2030-01-01 00:00:00", "2026-09-27 00:00:00", None),
        )
        database.execute(
            "INSERT INTO pairing_codes(id,user_id,token_hash,expires_at,redeemed_at,created_at) VALUES (?,?,?,?,?,?)",
            ("pairing", "owner", "pairing-hash", "2030-01-01 00:00:00", None, "2026-09-27 00:00:00"),
        )
        database.commit()
    (source.attachment_path / "encrypted-object").write_bytes(b"ciphertext")

    backup = backup_local(source, SERVER_ROOT, tmp_path / "backups")
    assert backup.is_file()
    status = backup_status(source)
    assert status["state"] == "healthy"
    assert status["archive"] == str(backup)
    assert status["size"] == backup.stat().st_size
    assert len(status["sha256"]) == 64
    assert status["destination"]["destination"] == "local_generation"
    assert source.backup_status_path.stat().st_mode & 0o777 == 0o600
    destination_path = tmp_path / "restored"
    restored = restore_local(backup, destination_path, SERVER_ROOT)
    assert restored.attachment_encryption_key == source.attachment_encryption_key
    assert restored.jwt_secret != source.jwt_secret
    assert (restored.attachment_path / "encrypted-object").read_bytes() == b"ciphertext"
    with sqlite3.connect(restored.database_path) as database:
        assert database.execute("SELECT display_name FROM users WHERE id='owner'").fetchone() == ("Owner",)
        assert database.execute("SELECT COUNT(*) FROM refresh_sessions").fetchone() == (0,)
        assert database.execute("SELECT COUNT(*) FROM pairing_codes").fetchone() == (0,)
        assert database.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    with sqlite3.connect(source.database_path) as database:
        assert database.execute("SELECT COUNT(*) FROM pairing_codes").fetchone() == (1,)
    restored_status = backup_status(restored)
    assert restored_status["state"] == "never"
    assert restored_status["last_restore_verification"]["state"] == "verified"
    assert restored_status["last_restore_verification"]["source_provider"] == "local_server_sqlite"
    assert len(restored_status["last_restore_verification"]["source_archive_sha256"]) == 64
    assert restored.recovery_status_path.stat().st_mode & 0o777 == 0o600
    with pytest.raises(LocalServerError, match="new, empty"):
        restore_local(backup, destination_path, SERVER_ROOT)


def test_corrupt_local_backup_never_creates_destination(tmp_path, monkeypatch):
    tools = tmp_path / "tools"
    tools.mkdir()
    age = tools / "age"
    age.write_text('#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == "--output" ]]; then output="$2"; shift 2; else input="$1"; shift; fi; done\ncp "$input" "$output"\n')
    age.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}:{os.environ['PATH']}")
    corrupt = tmp_path / "corrupt.tar.gz.age"
    corrupt.write_bytes(b"not an archive")
    destination = tmp_path / "must-not-exist"
    with pytest.raises(LocalServerError, match="validation failed"):
        restore_local(corrupt, destination, SERVER_ROOT)
    assert not destination.exists()
