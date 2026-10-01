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
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from typing import Iterator

try:
    from .backup_archive import create_manifest, extract_verified
    from .backup_health import carry_last_successful
    from .backup_destination import (
        DestinationError, DropboxDestination, DropboxHTTPTransport,
        LocalDirectoryDestination, dropbox_access_token, sha256_file,
    )
except ImportError:  # Direct script execution places this directory on sys.path.
    from backup_archive import create_manifest, extract_verified
    from backup_health import carry_last_successful
    from backup_destination import (
        DestinationError, DropboxDestination, DropboxHTTPTransport,
        LocalDirectoryDestination, dropbox_access_token, sha256_file,
    )


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

    @property
    def backup_status_path(self) -> Path:
        return self.data_directory / "backup-status.json"

    @property
    def recovery_status_path(self) -> Path:
        return self.data_directory / "recovery-status.json"

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
            existing = [item for item in data_directory.iterdir() if item.name != "server.lock"]
            if existing:
                raise LocalServerError(
                    "Local data exists without valid configuration; it was not reset or adopted"
                )
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

    @classmethod
    def create_with_attachment_key(
        cls, data_directory: Path, attachment_encryption_key: str,
    ) -> "LocalServerConfiguration":
        data_directory = data_directory.expanduser().resolve()
        if data_directory.exists() and any(data_directory.iterdir()):
            raise LocalServerError("Restore requires a new, empty local data directory")
        data_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        configuration = cls(
            data_directory=data_directory,
            jwt_secret=secrets.token_urlsafe(48),
            attachment_encryption_key=attachment_encryption_key,
            created_at=datetime.now(timezone.utc).isoformat(),
        )
        configuration.validate()
        path = configuration.config_path
        path.write_text(json.dumps({
            "format_version": CONFIG_VERSION,
            "created_at": configuration.created_at,
            "jwt_secret": configuration.jwt_secret,
            "attachment_encryption_key": configuration.attachment_encryption_key,
        }, sort_keys=True, indent=2) + "\n")
        os.chmod(path, 0o600)
        configuration.attachment_path.mkdir(mode=0o700)
        os.chmod(configuration.data_directory, 0o700)
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
            "BUDGET_APP_BACKUP_STATUS_PATH": str(self.backup_status_path),
            "BUDGET_APP_RECOVERY_STATUS_PATH": str(self.recovery_status_path),
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


def _copy_attachment_tree(source: Path, destination: Path) -> None:
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    for item in source.iterdir():
        if item.is_symlink() or not item.is_file():
            raise LocalServerError("Attachment storage contains an unsupported entry")
        target = destination / item.name
        with item.open("rb") as incoming, target.open("xb") as outgoing:
            shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
        os.chmod(target, 0o600)


def _age_executable() -> str:
    value = shutil.which("age")
    if not value:
        raise LocalServerError("age is required for encrypted local backups")
    return value


def _age_encrypt(source: Path, destination: Path) -> None:
    command = [_age_executable()]
    recipient = os.environ.get("BUDGET_APP_BACKUP_AGE_RECIPIENT", "").strip()
    if recipient:
        command += ["--recipient", recipient]
    else:
        command += ["--passphrase"]
    command += ["--output", str(destination), str(source)]
    if subprocess.run(command).returncode != 0:
        raise LocalServerError("Local backup encryption failed")


def _age_decrypt(source: Path, destination: Path) -> None:
    command = [_age_executable(), "--decrypt"]
    identity = os.environ.get("BUDGET_APP_BACKUP_AGE_IDENTITY", "").strip()
    if identity:
        identity_path = Path(identity).expanduser().resolve()
        if not identity_path.is_file():
            raise LocalServerError("Configured age identity file was not found")
        command += ["--identity", str(identity_path)]
    command += ["--output", str(destination), str(source)]
    if subprocess.run(command).returncode != 0:
        raise LocalServerError("Local backup decryption failed")


def _validate_sqlite_snapshot(path: Path) -> None:
    uri = f"file:{path}?mode=ro"
    try:
        with sqlite3.connect(uri, uri=True) as database:
            if database.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise LocalServerError("Local backup database integrity check failed")
            if database.execute("PRAGMA foreign_key_check").fetchall():
                raise LocalServerError("Local backup database foreign-key check failed")
            revision = database.execute("SELECT version_num FROM alembic_version").fetchone()
            if not revision or not revision[0]:
                raise LocalServerError("Local backup database has no migration revision")
    except sqlite3.Error as failure:
        raise LocalServerError("Local backup database is unreadable") from failure


def _publish_configured_backup(path: Path) -> dict[str, object] | None:
    selected = os.environ.get("BUDGET_APP_BACKUP_DESTINATION", "").strip()
    keep_text = os.environ.get("BUDGET_APP_BACKUP_RETENTION", "10")
    try:
        keep = int(keep_text)
    except ValueError as failure:
        raise LocalServerError("BUDGET_APP_BACKUP_RETENTION must be a positive integer") from failure
    if keep < 1:
        raise LocalServerError("BUDGET_APP_BACKUP_RETENTION must be a positive integer")
    if not selected:
        return None
    try:
        if selected == "local":
            directory = os.environ.get("BUDGET_APP_BACKUP_LOCAL_DIRECTORY", "").strip()
            if not directory:
                raise LocalServerError("BUDGET_APP_BACKUP_LOCAL_DIRECTORY is required")
            return LocalDirectoryDestination(Path(directory), keep).publish(path)
        if selected == "dropbox":
            transport = DropboxHTTPTransport(dropbox_access_token())
            return DropboxDestination(
                transport, os.environ.get("BUDGET_APP_DROPBOX_FOLDER", "/Backups"), keep
            ).publish(path)
    except DestinationError as failure:
        raise LocalServerError(f"Encrypted backup was retained locally, but publication failed: {failure}") from failure
    raise LocalServerError("BUDGET_APP_BACKUP_DESTINATION must be local, dropbox, or empty")


def _write_backup_status(
    configuration: LocalServerConfiguration, payload: dict[str, object],
) -> None:
    status = configuration.backup_status_path
    carry_last_successful(status, payload)
    temporary = status.with_name(f".{status.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, status)


def backup_status(configuration: LocalServerConfiguration) -> dict[str, object]:
    if not configuration.backup_status_path.is_file():
        value: dict[str, object] = {
            "state": "never", "message": "No completed local backup has been recorded"
        }
    else:
        try:
            value = json.loads(configuration.backup_status_path.read_text())
        except (OSError, ValueError) as failure:
            raise LocalServerError("Local backup status is unreadable") from failure
        if not isinstance(value, dict) or value.get("state") not in {"healthy", "publication_failed"}:
            raise LocalServerError("Local backup status is invalid")
    if configuration.recovery_status_path.is_file():
        try:
            recovery = json.loads(configuration.recovery_status_path.read_text())
        except (OSError, ValueError) as failure:
            raise LocalServerError("Local recovery status is unreadable") from failure
        if not isinstance(recovery, dict) or recovery.get("state") != "verified":
            raise LocalServerError("Local recovery status is invalid")
        value["last_restore_verification"] = recovery
    return value


def record_restore_verification(
    configuration: LocalServerConfiguration, source: Path, source_provider: str,
) -> None:
    payload: dict[str, object] = {
        "state": "verified",
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "source_provider": source_provider,
        "source_archive_sha256": sha256_file(source),
        "database_integrity": "ok",
        "foreign_keys": "ok",
    }
    status = configuration.recovery_status_path
    temporary = status.with_name(f".{status.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, status)


def backup_local(
    configuration: LocalServerConfiguration, server_directory: Path, output_directory: Path,
) -> Path:
    output_directory = output_directory.expanduser().resolve()
    output_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final = output_directory / f"budget-{timestamp}.tar.gz.age"
    if final.exists():
        raise LocalServerError("A local backup generation with this timestamp already exists")
    with exclusive_server_lock(configuration), tempfile.TemporaryDirectory(
        prefix=".budget-local-backup-", dir=output_directory
    ) as temporary_name:
        migrate(configuration, server_directory)
        root = Path(temporary_name) / "payload"
        root.mkdir(mode=0o700)
        snapshot = root / "database.sqlite3"
        with sqlite3.connect(configuration.database_path) as source, sqlite3.connect(snapshot) as destination:
            source.backup(destination)
            # Pairing codes are short-lived bearer credentials. Preserve the table
            # schema, but never let a valid code cross a backup boundary.
            if destination.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pairing_codes'"
            ).fetchone():
                destination.execute("DELETE FROM pairing_codes")
                destination.commit()
        _validate_sqlite_snapshot(snapshot)
        _copy_attachment_tree(configuration.attachment_path, root / "attachments")
        revision = migration_state(configuration, server_directory)
        (root / "BACKUP-METADATA").write_text(
            "format_version=2\n"
            "source_provider=local_server_sqlite\n"
            f"created_at={datetime.now(timezone.utc).isoformat()}\n"
            f"database_revision={revision}\n"
        )
        (root / "attachment-key-recovery.env").write_text(
            f"BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY={configuration.attachment_encryption_key}\n"
        )
        os.chmod(root / "attachment-key-recovery.env", 0o600)
        create_manifest(root)
        archive = Path(temporary_name) / "backup.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for name in ("BACKUP-METADATA", "database.sqlite3", "attachment-key-recovery.env", "MANIFEST.sha256", "attachments"):
                output.add(root / name, arcname=name, recursive=True)
        encrypted = Path(temporary_name) / "complete.age"
        _age_encrypt(archive, encrypted)
        os.link(encrypted, final)
        os.chmod(final, 0o600)
    base_status: dict[str, object] = {
        "archive": str(final),
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "sha256": sha256_file(final),
        "size": final.stat().st_size,
    }
    try:
        publication = _publish_configured_backup(final)
    except LocalServerError as failure:
        _write_backup_status(configuration, {
            **base_status, "state": "publication_failed", "error": str(failure),
            "destination": {"destination": "local_generation", "path": str(final)},
        })
        raise
    _write_backup_status(configuration, {
        **base_status,
        "state": "healthy",
        "destination": publication or {"destination": "local_generation", "path": str(final)},
    })
    return final


def restore_local(backup: Path, data_directory: Path, server_directory: Path) -> LocalServerConfiguration:
    backup = backup.expanduser().resolve()
    if not backup.is_file():
        raise LocalServerError("Encrypted local backup was not found")
    data_directory = data_directory.expanduser().resolve()
    if data_directory.exists():
        raise LocalServerError("Restore requires a new, empty local data directory")
    data_directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".budget-local-restore-", dir=data_directory.parent) as temporary_name:
        temporary = Path(temporary_name)
        archive = temporary / "backup.tar.gz"
        _age_decrypt(backup, archive)
        verified = temporary / "verified"
        try:
            extract_verified(archive, verified)
        except (OSError, ValueError, tarfile.TarError) as failure:
            raise LocalServerError("Encrypted local backup validation failed") from failure
        metadata = (verified / "BACKUP-METADATA").read_text().splitlines()
        if "format_version=2" not in metadata or "source_provider=local_server_sqlite" not in metadata:
            raise LocalServerError("Backup is not a personal local-server generation")
        key_line = (verified / "attachment-key-recovery.env").read_text().splitlines()
        prefix = "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY="
        if len(key_line) != 1 or not key_line[0].startswith(prefix):
            raise LocalServerError("Backup attachment recovery key is invalid")
        attachment_key = key_line[0][len(prefix):]
        _validate_sqlite_snapshot(verified / "database.sqlite3")
        staged_authority = temporary / "authority"
        configuration = LocalServerConfiguration.create_with_attachment_key(staged_authority, attachment_key)
        shutil.copy2(verified / "database.sqlite3", configuration.database_path)
        os.chmod(configuration.database_path, 0o600)
        # Recovery rotates the deployment signing secret. Revoke persisted refresh credentials too,
        # so an old device cannot mint a token under the replacement authority without reauthenticating.
        with sqlite3.connect(configuration.database_path) as recovered_database:
            recovered_database.execute("DELETE FROM refresh_sessions")
            recovered_database.commit()
        for item in (verified / "attachments").iterdir():
            if item.is_symlink() or not item.is_file():
                raise LocalServerError("Backup attachment payload is invalid")
            target = configuration.attachment_path / item.name
            shutil.copy2(item, target)
            os.chmod(target, 0o600)
        with exclusive_server_lock(configuration):
            migrate(configuration, server_directory)
        _validate_sqlite_snapshot(configuration.database_path)
        record_restore_verification(configuration, backup, "local_server_sqlite")
        os.rename(staged_authority, data_directory)
        return LocalServerConfiguration.load_or_create(data_directory)


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
    value.add_argument("command", choices=("init", "migrate", "doctor", "run", "backup", "backup-status", "restore"), nargs="?", default="run")
    value.add_argument("backup_file", type=Path, nargs="?")
    value.add_argument("--data-directory", type=Path, default=default_data_directory())
    value.add_argument("--output-directory", type=Path)
    value.add_argument("--host", default=os.environ.get("BUDGET_HOST", "127.0.0.1"))
    value.add_argument("--port", type=int, default=int(os.environ.get("BUDGET_PORT", "8000")))
    value.add_argument("--allowed-hosts", default="localhost,127.0.0.1")
    return value


def main(arguments: list[str] | None = None) -> int:
    args = parser().parse_args(arguments)
    server_directory = Path(__file__).resolve().parents[1]
    try:
        if args.command == "restore":
            if args.backup_file is None:
                raise LocalServerError("restore requires an encrypted backup path")
            configuration = restore_local(args.backup_file, args.data_directory, server_directory)
            print(f"Local backup restored into new authority at {configuration.data_directory}")
            return 0
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
        elif args.command == "backup":
            output = args.output_directory or (configuration.data_directory / "backups")
            result = backup_local(configuration, server_directory, output)
            print(f"Encrypted local backup complete: {result}")
        elif args.command == "backup-status":
            print(json.dumps(backup_status(configuration), sort_keys=True, indent=2))
        else:
            return run(configuration, server_directory, args.host, args.port, args.allowed_hosts)
        return 0
    except LocalServerError as failure:
        print(f"Local server error: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
