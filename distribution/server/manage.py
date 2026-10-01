#!/usr/bin/env python3
"""Operate a ClearPocket Server deployment without exposing or deleting its data."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Callable, Sequence
import urllib.error
import urllib.request


REQUIRED_KEYS = {
    "CLEARPOCKET_SERVER_IMAGE", "CLEARPOCKET_SERVER_VERSION",
    "CLEARPOCKET_BIND_ADDRESS", "CLEARPOCKET_PORT",
    "CLEARPOCKET_DATABASE_STORAGE", "CLEARPOCKET_ATTACHMENTS_STORAGE",
    "BUDGET_APP_ALLOWED_HOSTS", "BUDGET_APP_DB_PASSWORD",
    "BUDGET_APP_JWT_SECRET", "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY",
}
SECRET_KEYS = {
    "BUDGET_APP_DB_PASSWORD", "BUDGET_APP_JWT_SECRET",
    "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY",
}
SAFE_VALUE = re.compile(r"^[^\x00-\x1f\x7f]+$")
VERSION_VALUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


class ManagerError(RuntimeError):
    pass


@dataclass(frozen=True)
class Deployment:
    root: Path
    configuration_path: Path
    environment: dict[str, str]

    @property
    def compose_file(self) -> Path:
        return self.root / "compose.yaml"

    @property
    def environment_file(self) -> Path:
        return self.configuration_path

    @property
    def health_url(self) -> str:
        address = self.environment["CLEARPOCKET_BIND_ADDRESS"]
        if address == "0.0.0.0":
            address = "127.0.0.1"
        return f"http://{address}:{self.environment['CLEARPOCKET_PORT']}/api/v1/health"

    def compose_command(self, *arguments: str) -> list[str]:
        return ["docker", "compose", "--project-directory", str(self.root),
                "--env-file", str(self.environment_file), "-f", str(self.compose_file),
                *arguments]


def load_environment(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ManagerError(f"Cannot read private configuration at {path}: {error}") from error
    values: dict[str, str] = {}
    for number, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ManagerError(f"Invalid configuration syntax on line {number}")
        key, value = line.split("=", 1)
        if not key or key in values or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ManagerError(f"Invalid or duplicate configuration key on line {number}")
        if not value or not SAFE_VALUE.fullmatch(value):
            raise ManagerError(f"Missing or invalid value for {key}")
        values[key] = value
    missing = sorted(REQUIRED_KEYS - values.keys())
    if missing:
        raise ManagerError("Configuration is missing required settings: " + ", ".join(missing))
    try:
        port = int(values["CLEARPOCKET_PORT"])
    except ValueError as error:
        raise ManagerError("CLEARPOCKET_PORT must be a number") from error
    if not 1 <= port <= 65535:
        raise ManagerError("CLEARPOCKET_PORT must be between 1 and 65535")
    return values


def deployment(root: Path, environment_file: Path | None = None) -> Deployment:
    root = root.expanduser().resolve()
    if not (root / "compose.yaml").is_file():
        raise ManagerError(f"compose.yaml was not found in {root}")
    configuration_candidate = (environment_file or (root / ".env")).expanduser()
    if configuration_candidate.is_symlink() or not configuration_candidate.is_file():
        raise ManagerError(f"Private configuration must be a regular non-symlink file: {configuration_candidate}")
    configuration_path = configuration_candidate.resolve()
    return Deployment(root=root, configuration_path=configuration_path,
                      environment=load_environment(configuration_path))


Runner = Callable[..., subprocess.CompletedProcess[str]]


def run(command: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=check, text=True, capture_output=True)
    except FileNotFoundError as error:
        raise ManagerError("Docker was not found. Install and start Docker or QNAP Container Station.") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "command failed").strip()
        raise ManagerError(detail) from error


def run_interactive(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run a command attached to the operator terminal for secret prompts."""
    try:
        return subprocess.run(command, check=True, text=True)
    except FileNotFoundError as error:
        raise ManagerError("Docker was not found. Install and start Docker or QNAP Container Station.") from error
    except subprocess.CalledProcessError as error:
        raise ManagerError("Portable import failed; the server remains stopped for inspection") from error


def inspect_prerequisites(target: Deployment, runner: Runner = run) -> dict[str, str]:
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    compose = runner(["docker", "compose", "version", "--short"])
    runner(target.compose_command("config", "--quiet"))
    return {"docker_server": docker.stdout.strip(), "docker_compose": compose.stdout.strip()}


def health(url: str, timeout: float = 3.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def compose_services(target: Deployment, runner: Runner = run) -> list[dict[str, object]]:
    result = runner(target.compose_command("ps", "--format", "json"), check=False)
    if result.returncode != 0:
        raise ManagerError((result.stderr or result.stdout or "could not query services").strip())
    output = result.stdout.strip()
    if not output:
        return []
    try:
        decoded = json.loads(output)
        values = decoded if isinstance(decoded, list) else [decoded]
    except json.JSONDecodeError:
        try:
            values = [json.loads(line) for line in output.splitlines() if line.strip()]
        except json.JSONDecodeError as error:
            raise ManagerError("Docker returned an unsupported service-status response") from error
    return [value for value in values if isinstance(value, dict)]


def public_service(service: dict[str, object]) -> dict[str, str]:
    return {
        "service": str(service.get("Service", service.get("Name", "unknown"))),
        "state": str(service.get("State", "unknown")),
        "health": str(service.get("Health", "")),
    }


def start(target: Deployment, *, runner: Runner = run,
          health_check: Callable[[str, float], bool] = health,
          timeout: float = 120.0, pause: float = 2.0) -> None:
    inspect_prerequisites(target, runner)
    runner(target.compose_command("up", "-d"))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if health_check(target.health_url, 3.0):
            return
        time.sleep(pause)
    raise ManagerError("Server containers started but the API did not become healthy in time. "
                       "Run './manage.py diagnostics' and './manage.py logs'.")


def stop(target: Deployment, runner: Runner = run) -> None:
    runner(target.compose_command("stop"))


def storage_kind(value: str) -> str:
    return "host-directory" if value.startswith("/") or re.match(r"^[A-Za-z]:/", value) else "docker-volume"


def diagnostics(target: Deployment, destination: Path, runner: Runner = run) -> Path:
    prerequisites: dict[str, str] | None = None
    runtime_available = True
    services: list[dict[str, str]] = []
    try:
        prerequisites = inspect_prerequisites(target, runner)
        services = [public_service(item) for item in compose_services(target, runner)]
    except ManagerError:
        # Command errors can contain host paths or future Docker-supplied fields. Keep the
        # shareable report bounded; `doctor` remains the local, detailed diagnostic surface.
        runtime_available = False
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "server_image": target.environment["CLEARPOCKET_SERVER_IMAGE"],
        "server_version": target.environment["CLEARPOCKET_SERVER_VERSION"],
        "bind_address": target.environment["CLEARPOCKET_BIND_ADDRESS"],
        "port": int(target.environment["CLEARPOCKET_PORT"]),
        "database_storage": storage_kind(target.environment["CLEARPOCKET_DATABASE_STORAGE"]),
        "attachment_storage": storage_kind(target.environment["CLEARPOCKET_ATTACHMENTS_STORAGE"]),
        "operations_storage": storage_kind(target.environment.get(
            "CLEARPOCKET_OPERATIONS_STORAGE", "clearpocket_operations")),
        "health": "healthy" if health(target.health_url) else "unreachable",
        "runtime": prerequisites,
        "runtime_available": runtime_available,
        "services": services,
    }
    destination = destination.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return destination


def logs(target: Deployment, runner: Runner = run, lines: int = 200) -> str:
    return runner(target.compose_command("logs", "--no-color", "--tail", str(lines))).stdout


def backup(target: Deployment, destination: Path, runner: Runner = run,
           project_name: str = "clearpocket-server") -> None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", project_name):
        raise ManagerError("Backup project name is invalid")
    tool = target.root / "tools" / "backup.sh"
    if not tool.is_file():
        raise ManagerError("Backup tools are missing. Download the complete versioned server bundle.")
    destination = destination.expanduser().resolve()
    runner([str(tool), "--env-file", str(target.environment_file),
            "--project-name", project_name, str(destination)])


def restore(target: Deployment, archive: Path, runner: Runner = run,
            project_name: str = "clearpocket-recovery") -> None:
    """Restore a verified generation into this explicitly configured empty deployment."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", project_name):
        raise ManagerError("Recovery project name is invalid")
    tool = target.root / "tools" / "restore.sh"
    if not tool.is_file():
        raise ManagerError("Restore tools are missing. Download the complete versioned server bundle.")
    archive = archive.expanduser()
    if archive.is_symlink() or not archive.is_file():
        raise ManagerError("Recovery archive must be a regular non-symlink file")
    runner([
        str(tool), "--env-file", str(target.environment_file), "--yes",
        "--project-name", project_name, str(archive.resolve()),
    ])


def bundle_version(target: Deployment) -> str:
    version_file = target.root / "VERSION"
    try:
        value = version_file.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ManagerError("This server bundle has no immutable VERSION file") from error
    if not VERSION_VALUE.fullmatch(value) or value == "edge":
        raise ManagerError("The server bundle VERSION is not an immutable release version")
    return value


def bundle_image_reference(target: Deployment, version: str) -> tuple[str, str]:
    """Return the immutable pull reference and the local Compose tag for this bundle."""
    image = target.environment["CLEARPOCKET_SERVER_IMAGE"]
    tagged = f"{image}:{version}"
    metadata = target.root / "RELEASE-METADATA.txt"
    if not metadata.exists():
        # Source/development bundles predate release metadata and remain usable for operators.
        return tagged, tagged
    if metadata.is_symlink() or not metadata.is_file():
        raise ManagerError("Release metadata must be a regular non-symlink file")
    try:
        lines = metadata.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ManagerError("Release metadata could not be read") from error
    values: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            raise ManagerError("Release metadata is invalid")
        key, value = line.split("=", 1)
        if key in values or key not in {"version", "commit", "image"} or not value:
            raise ManagerError("Release metadata is invalid or ambiguous")
        values[key] = value
    if values.get("version") != version:
        raise ManagerError("Release metadata does not match the bundle version")
    reference = values.get("image", "")
    prefix = f"{image}@"
    if not reference.startswith(prefix) or not IMAGE_DIGEST.fullmatch(reference.removeprefix(prefix)):
        raise ManagerError("Release metadata does not contain the expected immutable image digest")
    return reference, tagged


def replace_environment_version(target: Deployment, version: str) -> None:
    if not VERSION_VALUE.fullmatch(version) or version == "edge":
        raise ManagerError("Refusing an invalid or mutable server version")
    path = target.environment_file
    lines = path.read_text(encoding="utf-8").splitlines()
    matches = [index for index, line in enumerate(lines)
               if line.startswith("CLEARPOCKET_SERVER_VERSION=")]
    if len(matches) != 1:
        raise ManagerError("Private configuration has an ambiguous server version")
    lines[matches[0]] = f"CLEARPOCKET_SERVER_VERSION={version}"
    temporary = path.with_name(f".{path.name}.{os.getpid()}.update")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write("\n".join(lines) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def upgrade(
    target: Deployment, backup_destination: Path, *, runner: Runner = run,
    health_check: Callable[[str, float], bool] = health,
    project_name: str = "clearpocket-server", timeout: float = 120.0,
) -> str:
    current = target.environment["CLEARPOCKET_SERVER_VERSION"]
    if current == "edge" or not VERSION_VALUE.fullmatch(current):
        raise ManagerError("Upgrade requires a currently pinned immutable server version")
    intended = bundle_version(target)
    if intended == current:
        raise ManagerError(f"Server is already configured for version {intended}")
    pull_reference, tagged_reference = bundle_image_reference(target, intended)
    inspect_prerequisites(target, runner)
    backup(target, backup_destination, runner, project_name)
    runner(["docker", "pull", pull_reference])
    if pull_reference != tagged_reference:
        runner(["docker", "tag", pull_reference, tagged_reference])
    replace_environment_version(target, intended)
    upgraded = deployment(target.root, target.environment_file)
    try:
        start(upgraded, runner=runner, health_check=health_check, timeout=timeout, pause=2.0)
    except ManagerError as error:
        raise ManagerError(
            f"Version {intended} did not become healthy. The pre-update encrypted backup was "
            "preserved. Automatic image rollback is intentionally disabled after migrations; "
            "keep this deployment isolated and follow the new-destination recovery workflow."
        ) from error
    return intended


def portable_import(
    target: Deployment, archive: Path, *, runner: Runner = run,
    interactive_runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] = run_interactive,
    health_check: Callable[[str, float], bool] = health, timeout: float = 120.0,
    age_identity: Path | None = None,
) -> None:
    """Import into a new empty authority without exposing credentials or overlaying data."""
    archive = archive.expanduser()
    if archive.is_symlink() or not archive.is_file():
        raise ManagerError("Portable import archive must be a regular non-symlink file")
    archive = archive.resolve()
    if age_identity is not None:
        age_identity = age_identity.expanduser()
        if age_identity.is_symlink() or not age_identity.is_file():
            raise ManagerError("Age identity must be a regular non-symlink file")
        age_identity = age_identity.resolve()
    inspect_prerequisites(target, runner)
    runner(target.compose_command("stop", "api"), check=False)
    runner(target.compose_command("up", "-d", "database"))
    run_arguments = [
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", f"{archive}:/import/archive.age:ro",
    ]
    prepare = "install -m 600 -o budget -g budget /import/archive.age /tmp/archive.age"
    if age_identity is not None:
        run_arguments += [
            "--volume", f"{age_identity}:/import/age-identity.txt:ro",
            "--env", "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/age-identity.txt",
        ]
        prepare += " && install -m 600 -o budget -g budget /import/age-identity.txt /tmp/age-identity.txt"
    operation = (
        "alembic upgrade head && python scripts/portable_import.py "
        "/tmp/archive.age --server-environment"
    )
    command = target.compose_command(
        *run_arguments, "api", "sh", "-c",
        f"{prepare} && exec su -s /bin/sh budget -c '{operation}'",
    )
    interactive_runner(command)
    refreshed = deployment(target.root, target.environment_file)
    start(refreshed, runner=runner, health_check=health_check, timeout=timeout, pause=2.0)


def verify_local_device_backup(
    target: Deployment, package: Path, *, runner: Runner = run,
    interactive_runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] = run_interactive,
) -> None:
    """Authenticate an iPhone backup in isolated staging without touching server authority."""
    package = package.expanduser()
    if package.is_symlink() or not package.is_dir():
        raise ManagerError("Local Device backup must be a regular non-symlink package directory")
    package = package.resolve()
    inspect_prerequisites(target, runner)
    command = target.compose_command(
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", f"{package}:/import/package:ro", "api", "sh", "-c",
        "cp -R /import/package /tmp/local-device-package && "
        "chown -R budget:budget /tmp/local-device-package && "
        "exec su -s /bin/sh budget -c 'python scripts/local_device_transfer.py "
        "/tmp/local-device-package'",
    )
    interactive_runner(command)


def local_device_import(
    target: Deployment, package: Path, *, runner: Runner = run,
    interactive_runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] = run_interactive,
    health_check: Callable[[str, float], bool] = health, timeout: float = 120.0,
) -> None:
    """Convert a verified phone authority into a new empty server and activate it."""
    package = package.expanduser()
    if package.is_symlink() or not package.is_dir():
        raise ManagerError("Local Device backup must be a regular non-symlink package directory")
    package = package.resolve()
    inspect_prerequisites(target, runner)
    runner(target.compose_command("stop", "api"), check=False)
    runner(target.compose_command("up", "-d", "database"))
    operation = (
        "alembic upgrade head && python scripts/local_device_transfer.py "
        "/tmp/local-device-package --server-environment"
    )
    command = target.compose_command(
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", f"{package}:/import/package:ro", "api", "sh", "-c",
        "cp -R /import/package /tmp/local-device-package && "
        "chown -R budget:budget /tmp/local-device-package && "
        f"exec su -s /bin/sh budget -c '{operation}'",
    )
    try:
        interactive_runner(command)
    except subprocess.CalledProcessError as error:
        raise ManagerError("Local Device import failed; the server remains stopped for inspection") from error
    refreshed = deployment(target.root, target.environment_file)
    start(refreshed, runner=runner, health_check=health_check, timeout=timeout, pause=2.0)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Safely operate a ClearPocket Server deployment")
    value.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                       help="directory containing compose.yaml and the private .env")
    value.add_argument("--env-file", type=Path,
                       help="private configuration path when stored outside the bundle (for example QNAP)")
    commands = value.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="validate Docker, Compose, and deployment configuration")
    commands.add_parser("status", help="show container and local API health")
    start_command = commands.add_parser("start", help="start services and wait for local API health")
    start_command.add_argument("--timeout", type=float, default=120.0)
    commands.add_parser("stop", help="stop services without deleting containers or data")
    log_command = commands.add_parser("logs", help="show recent service logs")
    log_command.add_argument("--lines", type=int, default=200)
    backup_command = commands.add_parser("backup", help="create a full encrypted database and attachment backup")
    backup_command.add_argument("--output", type=Path, required=True,
                                help="private directory for immutable encrypted backup generations")
    backup_command.add_argument("--project-name", default="clearpocket-server")
    restore_command = commands.add_parser(
        "restore", help="restore an encrypted backup into this configured empty recovery deployment",
    )
    restore_command.add_argument("archive", type=Path)
    restore_command.add_argument("--project-name", default="clearpocket-recovery")
    upgrade_command = commands.add_parser("upgrade", help="back up, apply the bundle version, and verify health")
    upgrade_command.add_argument("--backup-output", type=Path, required=True)
    upgrade_command.add_argument("--project-name", default="clearpocket-server")
    upgrade_command.add_argument("--timeout", type=float, default=120.0)
    import_command = commands.add_parser(
        "portable-import",
        help="restore a portable archive into a new empty customer server",
    )
    import_command.add_argument("archive", type=Path)
    import_command.add_argument(
        "--age-identity", type=Path,
        help="private age identity file mounted read-only for recipient-encrypted archives",
    )
    import_command.add_argument("--timeout", type=float, default=120.0)
    local_verify = commands.add_parser(
        "verify-local-device",
        help="authenticate an iPhone Local Device backup without modifying this server",
    )
    local_verify.add_argument("package", type=Path)
    local_import = commands.add_parser(
        "local-device-import",
        help="move an iPhone Local Device household into a new empty customer server",
    )
    local_import.add_argument("package", type=Path)
    local_import.add_argument("--timeout", type=float, default=120.0)
    diagnostic = commands.add_parser("diagnostics", help="write a redacted support report")
    diagnostic.add_argument("--output", type=Path, default=Path("clearpocket-diagnostics.json"))
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        target = deployment(arguments.root, arguments.env_file)
        if arguments.command == "doctor":
            versions = inspect_prerequisites(target)
            print(f"Docker {versions['docker_server']}; Compose {versions['docker_compose']}; configuration valid")
        elif arguments.command == "status":
            services = [public_service(item) for item in compose_services(target)]
            if not services:
                print("ClearPocket Server is stopped")
            for service in services:
                suffix = f" ({service['health']})" if service["health"] else ""
                print(f"{service['service']}: {service['state']}{suffix}")
            print(f"API: {'healthy' if health(target.health_url) else 'unreachable'}")
        elif arguments.command == "start":
            if arguments.timeout <= 0:
                raise ManagerError("Start timeout must be positive")
            start(target, timeout=arguments.timeout)
            print("ClearPocket Server is healthy")
        elif arguments.command == "stop":
            stop(target)
            print("ClearPocket Server stopped; database and attachments were preserved")
        elif arguments.command == "logs":
            if not 1 <= arguments.lines <= 10_000:
                raise ManagerError("Log line count must be between 1 and 10000")
            print(logs(target, lines=arguments.lines), end="")
        elif arguments.command == "backup":
            backup(target, arguments.output, project_name=arguments.project_name)
        elif arguments.command == "restore":
            restore(target, arguments.archive, project_name=arguments.project_name)
            print("Encrypted authority restored and recovery server started")
        elif arguments.command == "upgrade":
            if arguments.timeout <= 0:
                raise ManagerError("Upgrade timeout must be positive")
            version = upgrade(target, arguments.backup_output,
                              project_name=arguments.project_name, timeout=arguments.timeout)
            print(f"ClearPocket Server upgraded and healthy at version {version}")
        elif arguments.command == "portable-import":
            if arguments.timeout <= 0:
                raise ManagerError("Import health timeout must be positive")
            portable_import(
                target, arguments.archive, timeout=arguments.timeout,
                age_identity=arguments.age_identity,
            )
            print("Portable household imported; ClearPocket Server is healthy")
        elif arguments.command == "verify-local-device":
            verify_local_device_backup(target, arguments.package)
        elif arguments.command == "local-device-import":
            if arguments.timeout <= 0:
                raise ManagerError("Import health timeout must be positive")
            local_device_import(target, arguments.package, timeout=arguments.timeout)
            print("Local Device household imported; ClearPocket Server is healthy")
        elif arguments.command == "diagnostics":
            output = diagnostics(target, arguments.output)
            print(f"Redacted diagnostics written to {output}")
    except ManagerError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
