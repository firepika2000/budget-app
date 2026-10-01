#!/usr/bin/env python3
"""Operate a ClearPocket Server deployment without exposing or deleting its data."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
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


class ManagerError(RuntimeError):
    pass


@dataclass(frozen=True)
class Deployment:
    root: Path
    environment: dict[str, str]

    @property
    def compose_file(self) -> Path:
        return self.root / "compose.yaml"

    @property
    def environment_file(self) -> Path:
        return self.root / ".env"

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


def deployment(root: Path) -> Deployment:
    root = root.expanduser().resolve()
    if not (root / "compose.yaml").is_file():
        raise ManagerError(f"compose.yaml was not found in {root}")
    return Deployment(root=root, environment=load_environment(root / ".env"))


Runner = Callable[..., subprocess.CompletedProcess[str]]


def run(command: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=check, text=True, capture_output=True)
    except FileNotFoundError as error:
        raise ManagerError("Docker was not found. Install and start Docker or QNAP Container Station.") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "command failed").strip()
        raise ManagerError(detail) from error


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


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Safely operate a ClearPocket Server deployment")
    value.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                       help="directory containing compose.yaml and the private .env")
    commands = value.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="validate Docker, Compose, and deployment configuration")
    commands.add_parser("status", help="show container and local API health")
    start_command = commands.add_parser("start", help="start services and wait for local API health")
    start_command.add_argument("--timeout", type=float, default=120.0)
    commands.add_parser("stop", help="stop services without deleting containers or data")
    log_command = commands.add_parser("logs", help="show recent service logs")
    log_command.add_argument("--lines", type=int, default=200)
    diagnostic = commands.add_parser("diagnostics", help="write a redacted support report")
    diagnostic.add_argument("--output", type=Path, default=Path("clearpocket-diagnostics.json"))
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        target = deployment(arguments.root)
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
        elif arguments.command == "diagnostics":
            output = diagnostics(target, arguments.output)
            print(f"Redacted diagnostics written to {output}")
    except ManagerError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
