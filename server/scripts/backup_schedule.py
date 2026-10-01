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
import shlex
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
    candidate = path.expanduser()
    try:
        metadata = candidate.lstat()
    except FileNotFoundError as failure:
        raise BackupScheduleError("Scheduled-backup environment file was not found") from failure
    if candidate.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise BackupScheduleError("Scheduled-backup environment must be a regular non-symlink file")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise BackupScheduleError("Scheduled-backup environment must be owner-only (0600)")
    result: dict[str, str] = {}
    for line_number, line in enumerate(candidate.read_text().splitlines(), start=1):
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


def validate_private_compose_environment(path: Path) -> Path:
    candidate = path.expanduser()
    try:
        metadata = candidate.lstat()
    except FileNotFoundError as failure:
        raise BackupScheduleError("Compose environment file was not found") from failure
    if candidate.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise BackupScheduleError("Compose environment must be a regular non-symlink file")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise BackupScheduleError("Compose environment must be owner-only (0600)")
    return candidate.resolve()


def _atomic_status(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def record_schedule_status(
    path: Path, provider: str, hour: int, minute: int, retention: int | None = None,
) -> None:
    if provider not in {"launchd", "systemd", "windows_task", "qnap_cron"}:
        raise BackupScheduleError("Backup schedule provider is invalid")
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise BackupScheduleError("Backup schedule time is invalid")
    payload: dict[str, object] = {
        "state": "enabled",
        "provider": provider,
        "frequency": "daily",
        "hour": hour,
        "minute": minute,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    if retention is not None:
        if retention < 1:
            raise BackupScheduleError("Backup retention is invalid")
        payload["retention"] = retention
    candidate = path.expanduser()
    if candidate.is_symlink():
        raise BackupScheduleError("Backup schedule status cannot be a symbolic link")
    _atomic_status(candidate.resolve(), payload)


def configured_retention(environment_file: Path) -> int:
    raw = load_private_environment(environment_file).get("BUDGET_APP_BACKUP_RETENTION", "10")
    try:
        retention = int(raw)
    except ValueError as failure:
        raise BackupScheduleError("Backup retention is invalid") from failure
    if retention < 1:
        raise BackupScheduleError("Backup retention is invalid")
    return retention


def run_scheduled_backup(
    project_name: str, backup_directory: Path, environment_file: Path,
    backup_script: Path | None = None, compose_environment_file: Path | None = None,
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
        command = [str(script)]
        if compose_environment_file is not None:
            command += ["--env-file", str(validate_private_compose_environment(compose_environment_file))]
        command += ["--project-name", project_name, str(backup_directory)]
        result = subprocess.run(command, env=environment)
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
    hour: int, minute: int, compose_environment_file: Path | None = None,
) -> tuple[str, dict[str, object]]:
    project_name = validate_project_name(project_name)
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise BackupScheduleError("Backup schedule time is invalid")
    # Validate before installing so launchd cannot repeatedly invoke a broken/insecure configuration.
    load_private_environment(environment_file)
    label = f"com.firepika.budget-backup.{project_name}"
    backup_directory = backup_directory.expanduser().resolve()
    script = Path(__file__).resolve()
    program_arguments = [
        sys.executable, str(script), "run", "--project-name", project_name,
        "--backup-directory", str(backup_directory),
        "--environment-file", str(environment_file.expanduser().resolve()),
    ]
    if compose_environment_file is not None:
        program_arguments += ["--compose-env-file", str(validate_private_compose_environment(compose_environment_file))]
    payload: dict[str, object] = {
        "Label": label,
        "ProgramArguments": program_arguments,
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
    compose_environment_file: Path | None = None, schedule_status_file: Path | None = None,
) -> Path:
    if sys.platform != "darwin":
        raise BackupScheduleError("launchd scheduling is available only on macOS")
    label, payload = launch_agent_payload(project_name, backup_directory, environment_file, hour, minute,
                                          compose_environment_file)
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
    if schedule_status_file is not None:
        try:
            record_schedule_status(
                schedule_status_file, "launchd", hour, minute, configured_retention(environment_file)
            )
        except (BackupScheduleError, OSError):
            subprocess.run(
                ["launchctl", "bootout", domain, str(target)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            raise
    return target


def systemd_user_payload(
    project_name: str, backup_directory: Path, environment_file: Path,
    hour: int, minute: int, compose_environment_file: Path | None = None,
) -> tuple[str, str, str]:
    project_name = validate_project_name(project_name)
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise BackupScheduleError("Backup schedule time is invalid")
    load_private_environment(environment_file)
    arguments = [
        sys.executable, str(Path(__file__).resolve()), "run",
        "--project-name", project_name,
        "--backup-directory", str(backup_directory.expanduser().resolve()),
        "--environment-file", str(environment_file.expanduser().resolve()),
    ]
    if compose_environment_file is not None:
        arguments += ["--compose-env-file", str(validate_private_compose_environment(compose_environment_file))]
    name = f"clearpocket-backup-{project_name}"
    command = " ".join(shlex.quote(argument) for argument in arguments)
    service = (
        "[Unit]\nDescription=ClearPocket encrypted household backup\n\n"
        "[Service]\nType=oneshot\n"
        f"ExecStart={command}\n"
    )
    timer = (
        "[Unit]\nDescription=Daily ClearPocket encrypted household backup\n\n"
        "[Timer]\n"
        f"OnCalendar=*-*-* {hour:02d}:{minute:02d}:00\n"
        "Persistent=true\nUnit=" + name + ".service\n\n"
        "[Install]\nWantedBy=timers.target\n"
    )
    return name, service, timer


def install_systemd_user_timer(
    project_name: str, backup_directory: Path, environment_file: Path,
    hour: int, minute: int, unit_directory: Path | None = None,
    compose_environment_file: Path | None = None, schedule_status_file: Path | None = None,
) -> Path:
    if not sys.platform.startswith("linux"):
        raise BackupScheduleError("systemd user scheduling is available only on Linux")
    name, service, timer = systemd_user_payload(
        project_name, backup_directory, environment_file, hour, minute,
        compose_environment_file,
    )
    directory = unit_directory or (Path.home() / ".config" / "systemd" / "user")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    for suffix, contents in (("service", service), ("timer", timer)):
        target = directory / f"{name}.{suffix}"
        temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
        temporary.write_text(contents)
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    if subprocess.run(["systemctl", "--user", "daemon-reload"]).returncode != 0:
        raise BackupScheduleError("systemd could not reload user units")
    timer_name = f"{name}.timer"
    if subprocess.run(["systemctl", "--user", "enable", "--now", timer_name]).returncode != 0:
        raise BackupScheduleError("systemd could not enable the backup timer")
    if schedule_status_file is not None:
        try:
            record_schedule_status(
                schedule_status_file, "systemd", hour, minute, configured_retention(environment_file)
            )
        except (BackupScheduleError, OSError):
            subprocess.run(
                ["systemctl", "--user", "disable", "--now", timer_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            raise
    return directory / timer_name


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    install = commands.add_parser("install-launchd")
    install_systemd = commands.add_parser("install-systemd")
    for command in (run, install, install_systemd):
        command.add_argument("--project-name", required=True)
        command.add_argument("--backup-directory", type=Path, required=True)
        command.add_argument("--environment-file", type=Path, required=True)
        command.add_argument("--compose-env-file", type=Path)
    install.add_argument("--hour", type=int, default=3)
    install.add_argument("--minute", type=int, default=0)
    install.add_argument("--schedule-status-file", type=Path)
    install_systemd.add_argument("--hour", type=int, default=3)
    install_systemd.add_argument("--minute", type=int, default=0)
    install_systemd.add_argument("--schedule-status-file", type=Path)
    status = commands.add_parser("status")
    status.add_argument("--backup-directory", type=Path, required=True)
    return value


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    args = parser().parse_args(arguments)
    try:
        if args.command == "run":
            return run_scheduled_backup(
                args.project_name, args.backup_directory, args.environment_file,
                compose_environment_file=args.compose_env_file,
            )
        if args.command == "install-launchd":
            target = install_launch_agent(
                args.project_name, args.backup_directory, args.environment_file,
                args.hour, args.minute,
                compose_environment_file=args.compose_env_file,
                schedule_status_file=args.schedule_status_file,
            )
            print(f"Automatic backup schedule installed: {target}")
            return 0
        if args.command == "install-systemd":
            target = install_systemd_user_timer(
                args.project_name, args.backup_directory, args.environment_file,
                args.hour, args.minute, compose_environment_file=args.compose_env_file,
                schedule_status_file=args.schedule_status_file,
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
