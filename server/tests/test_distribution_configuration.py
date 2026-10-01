from __future__ import annotations

import base64
import importlib.util
import os
from pathlib import Path

import pytest

from app.attachment_storage import AttachmentStorage


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "distribution" / "server" / "configure.py"
SPEC = importlib.util.spec_from_file_location("deployment_configuration", SCRIPT)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def parsed(contents: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in contents.splitlines())


def test_configuration_generates_independent_exact_secrets_without_placeholders(tmp_path: Path):
    first = parsed(module.configuration(allowed_hosts="budget.example.com,192.168.1.20",
        bind_address="127.0.0.1", port=8443,
        image="ghcr.io/firepika2000/budget-server", version="0.9.0"))
    second = parsed(module.configuration(allowed_hosts="budget.example.com",
        bind_address="127.0.0.1", port=8443,
        image="ghcr.io/firepika2000/budget-server", version="0.9.0"))
    assert first["BUDGET_APP_ALLOWED_HOSTS"] == "budget.example.com,192.168.1.20"
    assert first["CLEARPOCKET_PORT"] == "8443"
    assert first["CLEARPOCKET_DATABASE_STORAGE"] == "clearpocket_database"
    assert first["CLEARPOCKET_ATTACHMENTS_STORAGE"] == "clearpocket_attachments"
    assert len(first["BUDGET_APP_DB_PASSWORD"]) >= 32
    assert len(first["BUDGET_APP_JWT_SECRET"]) >= 32
    assert first["BUDGET_APP_DB_PASSWORD"] != first["BUDGET_APP_JWT_SECRET"]
    assert first["BUDGET_APP_DB_PASSWORD"] != second["BUDGET_APP_DB_PASSWORD"]
    encoded = first["BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"]
    decoded = base64.urlsafe_b64decode(encoded)
    assert len(decoded) == 32
    vault = AttachmentStorage(str(tmp_path / "attachments"), first["BUDGET_APP_JWT_SECRET"], encoded)
    vault.write("object", b"encrypted attachment")
    assert vault.read("object") == b"encrypted attachment"
    assert not any("GENERATE" in value or "replace" in value for value in first.values())


@pytest.mark.parametrize("hosts", ["", "bad host", "example..com", "https://example.com", "a/b"])
def test_configuration_rejects_unsafe_allowed_hosts(hosts: str):
    with pytest.raises(module.ConfigurationError):
        module.configuration(allowed_hosts=hosts, bind_address="127.0.0.1", port=8080,
            image="ghcr.io/firepika2000/budget-server", version="edge")


def test_configuration_is_private_atomic_and_never_overwrites(tmp_path: Path):
    destination = tmp_path / ".env"
    contents = module.configuration(allowed_hosts="localhost", bind_address="127.0.0.1",
        port=8080, image="example/server", version="test")
    module.write_configuration(destination, contents)
    assert destination.read_text() == contents
    if os.name != "nt":
        assert destination.stat().st_mode & 0o777 == 0o600
    with pytest.raises(module.ConfigurationError):
        module.write_configuration(destination, "replacement")
    assert destination.read_text() == contents


@pytest.mark.parametrize("storage", ["../escape", "relative/path", "/data/${SECRET}", "name:other", "//server/share"])
def test_configuration_rejects_unsafe_storage(storage: str):
    with pytest.raises(module.ConfigurationError):
        module.configuration(allowed_hosts="localhost", bind_address="127.0.0.1", port=8080,
            image="example/server", version="test", database_storage=storage)


def test_configuration_accepts_named_posix_and_windows_storage():
    named = parsed(module.configuration(allowed_hosts="localhost", bind_address="127.0.0.1",
        port=8080, image="example/server", version="test",
        database_storage="customer_database", attachments_storage="/srv/clearpocket/attachments"))
    assert named["CLEARPOCKET_DATABASE_STORAGE"] == "customer_database"
    assert named["CLEARPOCKET_ATTACHMENTS_STORAGE"] == "/srv/clearpocket/attachments"
    windows = parsed(module.configuration(allowed_hosts="localhost", bind_address="127.0.0.1",
        port=8080, image="example/server", version="test",
        database_storage=r"D:\ClearPocket\database", attachments_storage=r"D:\ClearPocket\attachments"))
    assert windows["CLEARPOCKET_DATABASE_STORAGE"] == "D:/ClearPocket/database"


def test_shared_compose_contract_preserves_security_and_persistent_authority():
    compose = (ROOT / "distribution" / "server" / "compose.yaml").read_text()
    assert "ghcr.io/firepika2000/budget-server" in compose
    assert "postgres:17-alpine" in compose
    assert "read_only: true" in compose
    assert "no-new-privileges:true" in compose
    assert "cap_drop:" in compose and "- ALL" in compose
    assert "CLEARPOCKET_DATABASE_STORAGE:-clearpocket_database" in compose
    assert "CLEARPOCKET_ATTACHMENTS_STORAGE:-clearpocket_attachments" in compose
    assert "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY" in compose
    assert "CLEARPOCKET_BIND_ADDRESS:-127.0.0.1" in compose


def test_windows_launcher_uses_platform_crypto_and_has_no_python_dependency():
    command = (ROOT / "distribution" / "server" / "start-windows.cmd").read_text()
    script = (ROOT / "distribution" / "server" / "start-windows.ps1").read_text()
    assert "powershell.exe" in command
    assert "python" not in command.lower()
    assert "RandomNumberGenerator" in script
    assert 'Join-Path $PSScriptRoot "VERSION"' in script
    assert '"CLEARPOCKET_SERVER_VERSION=$serverVersion"' in script
    assert "CLEARPOCKET_DATABASE_STORAGE" in script
    assert "CLEARPOCKET_ATTACHMENTS_STORAGE" in script
    assert "Test-Path -LiteralPath $environmentFile" in script
    assert "Write-Host $lines" not in script
    assert "docker compose --env-file .env up -d" in script


def test_publish_workflow_builds_versioned_customer_bundle():
    workflow = (ROOT / ".github" / "workflows" / "server-image.yml").read_text()
    assert "Build customer deployment bundle" in workflow
    assert "distribution/server/." in workflow
    assert "clearpocket-server-$VERSION.zip" in workflow
    assert "clearpocket-server-$VERSION.tar.gz" in workflow
    assert "actions/upload-artifact@v4" in workflow
