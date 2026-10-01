#!/usr/bin/env python3
"""Create a private, no-overwrite ClearPocket Server deployment configuration."""

from __future__ import annotations

import argparse
import base64
import ipaddress
import os
from pathlib import Path
import re
import secrets
import tempfile


HOST = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|localhost)$")
IMAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VOLUME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
WINDOWS_PATH = re.compile(r"^[A-Za-z]:/[A-Za-z0-9 _./-]+$")


class ConfigurationError(ValueError):
    pass


def _hosts(value: str) -> str:
    values = [item.strip() for item in value.split(",") if item.strip()]
    if not values:
        raise ConfigurationError("At least one allowed hostname or IP address is required")
    for value in values:
        try:
            ipaddress.ip_address(value)
        except ValueError:
            if not HOST.fullmatch(value) or ".." in value:
                raise ConfigurationError(f"Invalid allowed host: {value}")
    return ",".join(dict.fromkeys(values))


def _bind_address(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise ConfigurationError("Bind address must be an explicit IPv4 address") from error
    if address.version != 4:
        raise ConfigurationError("The current Compose port contract requires an IPv4 bind address")
    return str(address)


def _storage(value: str) -> str:
    """Accept a Docker volume name or an absolute host bind path safe for .env/Compose."""
    value = value.strip().replace("\\", "/")
    if not value or any(character in value for character in "\r\n$\"'{}"):
        raise ConfigurationError("Storage must be a volume name or absolute host path")
    if ".." in Path(value).parts:
        raise ConfigurationError("Storage paths cannot contain parent-directory traversal")
    is_posix = value.startswith("/") and not value.startswith("//")
    is_windows = bool(WINDOWS_PATH.fullmatch(value))
    if not VOLUME.fullmatch(value) and not is_posix and not is_windows:
        raise ConfigurationError("Storage must be a safe volume name or absolute host path")
    if ":" in value and not is_windows:
        raise ConfigurationError("Storage paths cannot contain additional Compose separators")
    return value


def configuration(*, allowed_hosts: str, bind_address: str, port: int,
                  image: str, version: str,
                  database_storage: str = "clearpocket_database",
                  attachments_storage: str = "clearpocket_attachments") -> str:
    if not 1 <= port <= 65535:
        raise ConfigurationError("Port must be between 1 and 65535")
    if not IMAGE.fullmatch(image) or ".." in image:
        raise ConfigurationError("Container image reference is invalid")
    if not VERSION.fullmatch(version):
        raise ConfigurationError("Server version is invalid")
    attachment_key = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()
    values = {
        "CLEARPOCKET_SERVER_IMAGE": image,
        "CLEARPOCKET_SERVER_VERSION": version,
        "CLEARPOCKET_BIND_ADDRESS": _bind_address(bind_address),
        "CLEARPOCKET_PORT": str(port),
        "CLEARPOCKET_DATABASE_STORAGE": _storage(database_storage),
        "CLEARPOCKET_ATTACHMENTS_STORAGE": _storage(attachments_storage),
        "BUDGET_APP_ALLOWED_HOSTS": _hosts(allowed_hosts),
        "BUDGET_APP_DB_PASSWORD": secrets.token_urlsafe(36),
        "BUDGET_APP_JWT_SECRET": secrets.token_urlsafe(48),
        "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY": attachment_key,
    }
    return "".join(f"{key}={value}\n" for key, value in values.items())


def write_configuration(destination: Path, contents: str) -> None:
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise ConfigurationError(f"Refusing to overwrite existing configuration: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        if os.name != "nt":
            os.chmod(destination, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Create ClearPocket Server secrets and deployment settings")
    value.add_argument("--output", type=Path, default=Path(".env"))
    value.add_argument("--allowed-hosts", required=True,
                       help="Comma-separated hostnames/IPs clients use, for example budget.example.com")
    value.add_argument("--bind-address", default="127.0.0.1",
                       help="127.0.0.1 behind a proxy; 0.0.0.0 only on a protected LAN")
    value.add_argument("--port", type=int, default=8080)
    value.add_argument("--image", default="ghcr.io/firepika2000/budget-server")
    value.add_argument("--version", default="edge")
    value.add_argument("--database-storage", default="clearpocket_database",
                       help="Docker volume name or absolute host directory for PostgreSQL")
    value.add_argument("--attachments-storage", default="clearpocket_attachments",
                       help="Docker volume name or absolute host directory for encrypted attachments")
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        contents = configuration(allowed_hosts=arguments.allowed_hosts,
            bind_address=arguments.bind_address, port=arguments.port,
            image=arguments.image, version=arguments.version,
            database_storage=arguments.database_storage,
            attachments_storage=arguments.attachments_storage)
        write_configuration(arguments.output, contents)
    except (ConfigurationError, OSError) as error:
        parser().error(str(error))
    print(f"Created private configuration at {arguments.output}. Secrets were not printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
