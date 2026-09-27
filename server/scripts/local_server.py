#!/usr/bin/env python3
"""Self-contained single-user Budget Server storage and lifecycle.

This is the desktop-local backend mode. It uses the production API and migration graph with a
private SQLite authority. It is intentionally distinct from the future on-iPhone Local Device
repository and from deterministic Demo data.
"""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from typing import Iterator


CONFIG_VERSION = 1


class LocalServerError(RuntimeError):
    pass


def default_data_directory() -> Path:
    override = os.environ.get("BUDGET_APP_LOCAL_DATA_DIRECTORY", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    if sys.platform == "darwin":
        return (Path.home() / "Library" / "Application Support" / "Budget App Server").resolve()
    return (Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "budget-app-server").resolve()


@dataclass(frozen=True)
class LocalServerConfiguration:
    data_directory: Path
    jwt_secret: str
    attachment_encryption_key: str
    created_at: str

    @property
    def database_path(self) -> Path:
        return self.data_directory / "budget.sqlite3"

    @property
    def attachment_path(self) -> Path:
        return self.data_directory / "attachments"

    @property
    def config_path(self) -> Path:
        return self.data_directory / "configuration.json"

    @property
    def lock_path(self) -> Path:
        return self.data_directory / "server.lock"

    @classmethod
    def load_or_create(cls, data_directory: Path) -> "LocalServerConfiguration":
        data_directory = data_directory.expanduser().resolve()
        data_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(data_directory, 0o700)
        path = data_directory / "configuration.json"
        if path.exists():
            try:
                payload = json.loads(path.read_text())
                if payload.get("format_version") != CONFIG_VERSION:
                    raise LocalServerError("Local server configuration uses an unsupported version")
                configuration = cls(
                    data_directory=data_directory,
                    jwt_secret=str(payload["jwt_secret"]),
                    attachment_encryption_key=str(payload["attachment_encryption_key"]),
                    created_at=str(payload["created_at"]),
                )
            except (OSError, ValueError, KeyError, TypeError) as failure:
                raise LocalServerError("Local server configuration is invalid; it was not replaced") from failure
            configuration.validate()
            os.chmod(path, 0o600)
        else:
            configuration = cls(
                data_directory=data_directory,
                jwt_secret=secrets.token_urlsafe(48),
                attachment_encryption_key=base64.urlsafe_b64encode(secrets.token_bytes(32)).decode(),
                created_at=datetime.now(timezone.utc).isoformat(),
            )
            temporary = data_directory / f".{path.name}.{secrets.token_hex(8)}.tmp"
            temporary.write_text(json.dumps({
                "format_version": CONFIG_VERSION,
                "created_at": configuration.created_at,
                "jwt_secret": configuration.jwt_secret,
                "attachment_encryption_key": configuration.attachment_encryption_key,
            }, sort_keys=True, indent=2) + "\n")
            os.chmod(temporary, 0o600)
            try:
                os.link(temporary, path)
            except FileExistsError:
                return cls.load_or_create(data_directory)
            finally:
                temporary.unlink(missing_ok=True)
        configuration.attachment_path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(configuration.attachment_path, 0o700)
        return configuration

    def validate(self) -> None:
        if len(self.jwt_secret) < 32:
            raise LocalServerError("Local JWT secret is invalid")
        try:
            attachment_key = base64.urlsafe_b64decode(self.attachment_encryption_key)
        except ValueError as failure:
            raise LocalServerError("Local attachment encryption key is invalid") from failure
        if len(attachment_key) != 32:
            raise LocalServerError("Local attachment encryption key is invalid")

    def environment(self, allowed_hosts: str = "localhost,127.0.0.1") -> dict[str, str]:
        value = dict(os.environ)
        value.update({
            "BUDGET_APP_DATABASE_URL": f"sqlite:///{self.database_path}",
            "BUDGET_APP_JWT_SECRET": self.jwt_secret,
            "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY": self.attachment_encryption_key,
            "BUDGET_APP_ATTACHMENT_STORAGE_PATH": str(self.attachment_path),
            "BUDGET_APP_ALLOWED_HOSTS": allowed_hosts,
        })
        return value


@contextmanager
def exclusive_server_lock(configuration: LocalServerConfiguration) -> Iterator[None]:
    descriptor = os.open(configuration.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as failure:
            raise LocalServerError("This local Budget Server data directory is already in use") from failure
        os.ftruncate(descriptor, 0)
        os.write(descriptor, f"pid={os.getpid()}\n".encode())
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def tool(name: str) -> Path:
    # Keep the virtual-environment path. Resolving its Python symlink would jump to the base
    # interpreter and lose the sibling Alembic/Uvicorn entry points.
    candidate = Path(sys.executable).parent / name
    if not candidate.is_file():
        raise LocalServerError(f"The local Python environment is missing {name}")
    return candidate


def migrate(configuration: LocalServerConfiguration, server_directory: Path) -> None:
    result = subprocess.run(
        [str(tool("alembic")), "upgrade", "head"],
        cwd=server_directory,
        env=configuration.environment(),
    )
    if result.returncode != 0:
        raise LocalServerError("Local database migration failed; existing data was not reset")


def migration_state(configuration: LocalServerConfiguration, server_directory: Path) -> str:
    result = subprocess.run(
        [str(tool("alembic")), "current"],
        cwd=server_directory,
        env=configuration.environment(),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise LocalServerError("Local database migration state is unavailable")
    return result.stdout.strip()


def run(
    configuration: LocalServerConfiguration, server_directory: Path,
    host: str, port: int, allowed_hosts: str,
) -> int:
    if host not in {"127.0.0.1", "localhost", "::1"} and allowed_hosts == "localhost,127.0.0.1":
        raise LocalServerError(
            "Non-loopback binding requires explicit --allowed-hosts and a trusted private-network plan"
        )
    with exclusive_server_lock(configuration):
        migrate(configuration, server_directory)
        print("\nBudget App Personal Local Server")
        print("--------------------------------")
        print(f"Data:      {configuration.data_directory}")
        print(f"Server:    http://{host}:{port}")
        print("Authority: private single-user SQLite (not Demo and not Dropbox sync)")
        print("Press Ctrl+C to stop.\n")
        try:
            result = subprocess.run(
                [str(tool("uvicorn")), "--factory", "app.main:create_app", "--host", host, "--port", str(port)],
                cwd=server_directory,
                env=configuration.environment(allowed_hosts),
            )
            return result.returncode
        except KeyboardInterrupt:
            return 0


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Manage the single-user desktop-local Budget Server")
    value.add_argument("command", choices=("init", "migrate", "doctor", "run"), nargs="?", default="run")
    value.add_argument("--data-directory", type=Path, default=default_data_directory())
    value.add_argument("--host", default=os.environ.get("BUDGET_HOST", "127.0.0.1"))
    value.add_argument("--port", type=int, default=int(os.environ.get("BUDGET_PORT", "8000")))
    value.add_argument("--allowed-hosts", default="localhost,127.0.0.1")
    return value


def main(arguments: list[str] | None = None) -> int:
    args = parser().parse_args(arguments)
    server_directory = Path(__file__).resolve().parents[1]
    try:
        configuration = LocalServerConfiguration.load_or_create(args.data_directory)
        if args.command == "init":
            print(f"Local Budget Server initialized at {configuration.data_directory}")
        elif args.command == "migrate":
            with exclusive_server_lock(configuration):
                migrate(configuration, server_directory)
            print(f"Local database is current: {migration_state(configuration, server_directory)}")
        elif args.command == "doctor":
            state = migration_state(configuration, server_directory) if configuration.database_path.exists() else "not migrated"
            print(f"Data directory: {configuration.data_directory}")
            print(f"Configuration: valid and private")
            print(f"Database: {state}")
            print(f"Attachments: {configuration.attachment_path}")
        else:
            return run(configuration, server_directory, args.host, args.port, args.allowed_hosts)
        return 0
    except LocalServerError as failure:
        print(f"Local server error: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
