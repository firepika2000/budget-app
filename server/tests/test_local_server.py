from __future__ import annotations

import base64
import os
from pathlib import Path
import sqlite3

import pytest

from scripts.local_server import LocalServerConfiguration, LocalServerError, exclusive_server_lock, migrate, migration_state, run


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
    assert "0030_import_staging (head)" in migration_state(configuration, SERVER_ROOT)
    with sqlite3.connect(configuration.database_path) as database:
        database.execute("INSERT INTO users(id,email,password_hash,display_name,created_at) VALUES (?,?,?,?,?)",
                         ("owner", "owner@example.test", "hash", "Owner", "2026-09-27 00:00:00"))
        database.commit()

    migrate(configuration, SERVER_ROOT)
    with sqlite3.connect(configuration.database_path) as database:
        assert database.execute("SELECT display_name FROM users WHERE id='owner'").fetchone() == ("Owner",)
