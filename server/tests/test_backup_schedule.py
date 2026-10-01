from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from scripts.backup_schedule import (
    BackupScheduleError, launch_agent_payload, load_private_environment,
    run_scheduled_backup, systemd_user_payload, validate_private_compose_environment,
)


def environment_file(tmp_path: Path, text: str | None = None) -> Path:
    tmp_path.mkdir(parents=True, exist_ok=True)
    value = tmp_path / "backup.env"
    value.write_text(text or (
        "BUDGET_APP_BACKUP_AGE_RECIPIENT=age1owner\n"
        "BUDGET_APP_BACKUP_DESTINATION=dropbox\n"
        "BUDGET_APP_DROPBOX_REFRESH_TOKEN=private-refresh\n"
        "BUDGET_APP_DROPBOX_APP_KEY=public-app-key\n"
        "BUDGET_APP_BACKUP_RETENTION=10\n"
    ))
    value.chmod(0o600)
    return value


def fake_backup(tmp_path: Path, exit_code: int = 0) -> Path:
    value = tmp_path / "backup.sh"
    value.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        "test -n \"$BUDGET_APP_BACKUP_AGE_RECIPIENT\"\n"
        "test -n \"$BUDGET_APP_DROPBOX_REFRESH_TOKEN\"\n"
        "[[ -z \"${BACKUP_ARGUMENT_LOG:-}\" ]] || printf '%s\\n' \"$@\" > \"$BACKUP_ARGUMENT_LOG\"\n"
        "directory=\"${@: -1}\"\n"
        "printf 'age-encryption.org/v1\\nfixture' > \"$directory/budget-20260927T120000Z.tar.gz.age\"\n"
        f"exit {exit_code}\n"
    )
    value.chmod(0o700)
    return value


def test_private_environment_is_allowlisted_and_never_embedded_in_launch_agent(tmp_path):
    env = environment_file(tmp_path)
    loaded = load_private_environment(env)
    assert loaded["BUDGET_APP_DROPBOX_REFRESH_TOKEN"] == "private-refresh"

    label, payload = launch_agent_payload("family", tmp_path / "backups", env, 3, 15)

    assert label == "com.firepika.budget-backup.family"
    serialized = json.dumps(payload)
    assert "private-refresh" not in serialized
    assert str(env) in payload["ProgramArguments"]
    assert payload["StartCalendarInterval"] == {"Hour": 3, "Minute": 15}


def test_environment_rejects_insecure_permissions_unknown_keys_and_passphrase_mode(tmp_path):
    insecure = environment_file(tmp_path)
    insecure.chmod(0o644)
    with pytest.raises(BackupScheduleError, match="0600"):
        load_private_environment(insecure)
    unknown = environment_file(tmp_path, "BUDGET_APP_BACKUP_AGE_RECIPIENT=age1owner\nPASSWORD=secret\n")
    with pytest.raises(BackupScheduleError, match="Unsupported"):
        load_private_environment(unknown)
    missing_recipient = environment_file(tmp_path, "BUDGET_APP_BACKUP_DESTINATION=\n")
    with pytest.raises(BackupScheduleError, match="AGE_RECIPIENT"):
        load_private_environment(missing_recipient)
    target = environment_file(tmp_path / "target")
    link = tmp_path / "linked.env"
    link.symlink_to(target)
    with pytest.raises(BackupScheduleError, match="non-symlink"):
        load_private_environment(link)


def test_scheduled_run_inherits_private_configuration_and_records_health(tmp_path):
    backup_directory = tmp_path / "backups"
    status = run_scheduled_backup(
        "family", backup_directory, environment_file(tmp_path), fake_backup(tmp_path)
    )

    assert status == 0
    recorded = json.loads((backup_directory / "scheduled-backup-status.json").read_text())
    assert recorded["state"] == "healthy"
    assert recorded["project_name"] == "family"
    assert recorded["exit_code"] == 0
    assert recorded["latest_generation"].endswith("budget-20260927T120000Z.tar.gz.age")
    assert "private-refresh" not in json.dumps(recorded)


def test_scheduled_failure_is_visible_and_returns_failure(tmp_path):
    backup_directory = tmp_path / "backups"
    status = run_scheduled_backup(
        "family", backup_directory, environment_file(tmp_path), fake_backup(tmp_path, exit_code=7)
    )

    assert status == 7
    recorded = json.loads((backup_directory / "scheduled-backup-status.json").read_text())
    assert recorded["state"] == "failed"
    assert recorded["exit_code"] == 7


def test_external_compose_environment_is_private_and_forwarded_without_embedding_secrets(tmp_path, monkeypatch):
    backup_environment = environment_file(tmp_path)
    compose_environment = tmp_path / "deployment.env"
    compose_environment.write_text("BUDGET_APP_DB_PASSWORD=database-secret\n")
    compose_environment.chmod(0o600)
    assert validate_private_compose_environment(compose_environment) == compose_environment.resolve()

    argument_log = tmp_path / "arguments.log"
    monkeypatch.setenv("BACKUP_ARGUMENT_LOG", str(argument_log))
    status = run_scheduled_backup(
        "family", tmp_path / "backups", backup_environment, fake_backup(tmp_path),
        compose_environment_file=compose_environment,
    )
    assert status == 0
    arguments = argument_log.read_text().splitlines()
    assert arguments[:2] == ["--env-file", str(compose_environment)]

    label, launch = launch_agent_payload(
        "family", tmp_path / "backups", backup_environment, 3, 15, compose_environment,
    )
    name, service, timer = systemd_user_payload(
        "family", tmp_path / "backups", backup_environment, 3, 15, compose_environment,
    )
    serialized = json.dumps(launch) + service + timer
    assert label == "com.firepika.budget-backup.family"
    assert name == "clearpocket-backup-family"
    assert str(compose_environment) in serialized
    assert "database-secret" not in serialized
    assert "private-refresh" not in serialized
    assert "OnCalendar=*-*-* 03:15:00" in timer
    assert "Persistent=true" in timer
