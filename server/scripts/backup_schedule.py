#!/usr/bin/env python3
"""Install and run unattended macOS Budget Server backup schedules."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys


class BackupScheduleError(RuntimeError):
    pass


PROJECT_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
ALLOWED_ENVIRONMENT_KEYS = {
    "BUDGET_APP_BACKUP_AGE_RECIPIENT",
    "BUDGET_APP_BACKUP_DESTINATION",
    "BUDGET_APP_BACKUP_LOCAL_DIRECTORY",
    "BUDGET_APP_BACKUP_RETENTION",
    "BUDGET_APP_DROPBOX_FOLDER",
    "BUDGET_APP_DROPBOX_REFRESH_TOKEN",
    "BUDGET_APP_DROPBOX_APP_KEY",
    "BUDGET_APP_DROPBOX_APP_SECRET",
    "BUDGET_APP_DROPBOX_ACCESS_TOKEN",
}


def validate_project_name(value: str) -> str:
    if not PROJECT_PATTERN.fullmatch(value):
        raise BackupScheduleError("Invalid Docker Compose project name")
    return value


def load_private_environment(path: Path) -> dict[str, str]:
    path = path.expanduser().resolve()
    try:
        metadata = path.lstat()
    except FileNotFoundError as failure:
        raise BackupScheduleError("Scheduled-backup environment file was not found") from failure
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise BackupScheduleError("Scheduled-backup environment must be a regular non-symlink file")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise BackupScheduleError("Scheduled-backup environment must be owner-only (0600)")
    result: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise BackupScheduleError(f"Invalid environment entry on line {line_number}")
        key, value = stripped.split("=", 1)
        if key not in ALLOWED_ENVIRONMENT_KEYS:
            raise BackupScheduleError(f"Unsupported scheduled-backup setting: {key}")
        if (not value and key != "BUDGET_APP_BACKUP_DESTINATION") or "\x00" in value or "\n" in value:
            raise BackupScheduleError(f"Invalid scheduled-backup value: {key}")
        result[key] = value
    if not result.get("BUDGET_APP_BACKUP_AGE_RECIPIENT"):
        raise BackupScheduleError("Unattended backup requires BUDGET_APP_BACKUP_AGE_RECIPIENT")
    destination = result.get("BUDGET_APP_BACKUP_DESTINATION", "")
    if destination not in {"", "local", "dropbox"}:
        raise BackupScheduleError("Backup destination must be local, dropbox, or empty")
    if destination == "local" and not result.get("BUDGET_APP_BACKUP_LOCAL_DIRECTORY"):
        raise BackupScheduleError("Local scheduled backup requires BUDGET_APP_BACKUP_LOCAL_DIRECTORY")
    if destination == "dropbox" and not (
        result.get("BUDGET_APP_DROPBOX_ACCESS_TOKEN")
        or (result.get("BUDGET_APP_DROPBOX_REFRESH_TOKEN") and result.get("BUDGET_APP_DROPBOX_APP_KEY"))
    ):
        raise BackupScheduleError("Dropbox scheduled backup credentials are incomplete")
    return result


def _atomic_status(path: Path, payload: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def run_scheduled_backup(
    project_name: str, backup_directory: Path, environment_file: Path,
    backup_script: Path | None = None,
) -> int:
    project_name = validate_project_name(project_name)
    backup_directory = backup_directory.expanduser().resolve()
    backup_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    environment = dict(os.environ)
    environment.update(load_private_environment(environment_file))
    script = backup_script or Path(__file__).resolve().with_name("backup.sh")
    if not script.is_file():
        raise BackupScheduleError("Coordinated backup script was not found")
    lock_path = backup_directory / "scheduled-backup.lock"
    status_path = backup_directory / "scheduled-backup-status.json"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            _atomic_status(status_path, {
                "state": "already_running", "observed_at": datetime.now(timezone.utc).isoformat(),
                "project_name": project_name,
            })
            return 0
        started = datetime.now(timezone.utc)
        result = subprocess.run(
            [str(script), "--project-name", project_name, str(backup_directory)],
            env=environment,
        )
        completed = datetime.now(timezone.utc)
        generations = sorted(
            (item for item in backup_directory.glob("budget-*.tar.gz.age") if item.is_file()),
            key=lambda item: (item.stat().st_mtime_ns, item.name), reverse=True,
        )
        payload: dict[str, object] = {
            "state": "healthy" if result.returncode == 0 else "failed",
            "project_name": project_name,
            "started_at": started.isoformat(),
            "completed_at": completed.isoformat(),
            "exit_code": result.returncode,
        }
        if generations:
            payload["latest_generation"] = str(generations[0])
        _atomic_status(status_path, payload)
        return result.returncode
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def launch_agent_payload(
    project_name: str, backup_directory: Path, environment_file: Path,
    hour: int, minute: int,
) -> tuple[str, dict[str, object]]:
    project_name = validate_project_name(project_name)
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise BackupScheduleError("Backup schedule time is invalid")
    # Validate before installing so launchd cannot repeatedly invoke a broken/insecure configuration.
    load_private_environment(environment_file)
    label = f"com.firepika.budget-backup.{project_name}"
    backup_directory = backup_directory.expanduser().resolve()
    script = Path(__file__).resolve()
    payload: dict[str, object] = {
        "Label": label,
        "ProgramArguments": [
            sys.executable, str(script), "run", "--project-name", project_name,
            "--backup-directory", str(backup_directory),
            "--environment-file", str(environment_file.expanduser().resolve()),
        ],
        "StartCalendarInterval": {"Hour": hour, "Minute": minute},
        "RunAtLoad": False,
        "StandardOutPath": str(backup_directory / "scheduled-backup.log"),
        "StandardErrorPath": str(backup_directory / "scheduled-backup-error.log"),
        "ProcessType": "Background",
    }
    return label, payload


def install_launch_agent(
    project_name: str, backup_directory: Path, environment_file: Path,
    hour: int, minute: int, launch_agents_directory: Path | None = None,
) -> Path:
    if sys.platform != "darwin":
        raise BackupScheduleError("launchd scheduling is available only on macOS")
    label, payload = launch_agent_payload(project_name, backup_directory, environment_file, hour, minute)
    backup_directory = backup_directory.expanduser().resolve()
    backup_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = launch_agents_directory or (Path.home() / "Library" / "LaunchAgents")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = directory / f"{label}.plist"
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    temporary.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True))
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", domain, str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if subprocess.run(["launchctl", "bootstrap", domain, str(target)]).returncode != 0:
        raise BackupScheduleError("launchd could not activate the backup schedule")
    return target


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    install = commands.add_parser("install-launchd")
    for command in (run, install):
        command.add_argument("--project-name", required=True)
        command.add_argument("--backup-directory", type=Path, required=True)
        command.add_argument("--environment-file", type=Path, required=True)
    install.add_argument("--hour", type=int, default=3)
    install.add_argument("--minute", type=int, default=0)
    status = commands.add_parser("status")
    status.add_argument("--backup-directory", type=Path, required=True)
    return value


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    args = parser().parse_args(arguments)
    try:
        if args.command == "run":
            return run_scheduled_backup(
                args.project_name, args.backup_directory, args.environment_file
            )
        if args.command == "install-launchd":
            target = install_launch_agent(
                args.project_name, args.backup_directory, args.environment_file,
                args.hour, args.minute,
            )
            print(f"Automatic backup schedule installed: {target}")
            return 0
        status = args.backup_directory.expanduser().resolve() / "scheduled-backup-status.json"
        if not status.is_file():
            print(json.dumps({"state": "never"}, sort_keys=True))
        else:
            print(status.read_text(), end="")
        return 0
    except (BackupScheduleError, OSError) as failure:
        print(f"Backup schedule error: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
