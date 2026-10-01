from __future__ import annotations

import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from app.attachment_storage import AttachmentStorage


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "distribution" / "server" / "configure.py"
SPEC = importlib.util.spec_from_file_location("deployment_configuration", SCRIPT)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
MANAGER_SCRIPT = ROOT / "distribution" / "server" / "manage.py"
MANAGER_SPEC = importlib.util.spec_from_file_location("deployment_manager", MANAGER_SCRIPT)
assert MANAGER_SPEC and MANAGER_SPEC.loader
manager = importlib.util.module_from_spec(MANAGER_SPEC)
sys.modules[MANAGER_SPEC.name] = manager
MANAGER_SPEC.loader.exec_module(manager)


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
    assert first["CLEARPOCKET_OPERATIONS_STORAGE"] == "clearpocket_operations"
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
    assert "CLEARPOCKET_OPERATIONS_STORAGE:-clearpocket_operations" in compose
    assert "BUDGET_APP_BACKUP_STATUS_PATH" in compose
    assert "BUDGET_APP_RECOVERY_STATUS_PATH" in compose
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
    assert "CLEARPOCKET_OPERATIONS_STORAGE" in script
    assert "Test-Path -LiteralPath $environmentFile" in script
    assert "Write-Host $lines" not in script
    assert "Start-ClearPocketServer" in script
    assert 'Invoke-ClearPocketCompose @(\"up\", \"-d\")' in script
    assert 'Invoke-ClearPocketCompose @(\"stop\")' in script
    assert "Test-ClearPocketHealth" in script
    assert "^CLEARPOCKET_PORT=" in script
    assert "$healthUrl" in script
    assert "Start-Process $adminUrl" in script
    assert "Write-ClearPocketDiagnostics" in script
    assert "BUDGET_APP_JWT_SECRET" not in script.split("function Write-ClearPocketDiagnostics", 1)[1]
    assert "down -v" not in script
    assert "docker volume rm" not in script


def test_publish_workflow_builds_versioned_customer_bundle():
    workflow = (ROOT / ".github" / "workflows" / "server-image.yml").read_text()
    assert "Build customer deployment bundle" in workflow
    assert "distribution/server/." in workflow
    assert "clearpocket-server-$VERSION.zip" in workflow
    assert "clearpocket-server-$VERSION.tar.gz" in workflow
    assert "actions/upload-artifact@v4" in workflow
    assert "server/scripts/backup.sh server/scripts/restore.sh" in workflow
    assert "server/scripts/backup_archive.py server/scripts/backup_destination.py" in workflow


def test_qnap_qpkg_source_uses_shared_compose_and_preserves_customer_authority():
    root = ROOT / "distribution" / "qnap"
    config = (root / "template" / "qpkg.cfg").read_text()
    routines = (root / "template" / "package_routines").read_text()
    service = (root / "template" / "shared" / "ClearPocketServer.sh").read_text()
    builder = (root / "build.sh").read_text()
    assert 'QPKG_NAME="ClearPocketServer"' in config
    assert 'QPKG_SERVICE_PROGRAM="ClearPocketServer.sh"' in config
    assert "Container Station must be installed" in routines
    assert "CLEARPOCKET_DATA_ROOT" in routines
    assert "PKG_MAIN_REMOVE" not in routines
    assert "CLEARPOCKET_DATA_ROOT" in service
    assert 'compose up -d' in service
    assert 'compose stop' in service
    assert 'compose ps' in service
    assert "down -v" not in service
    assert "docker volume rm" not in service
    assert 'distribution/server/compose.yaml' in builder
    assert 'distribution/server/manage.py' in builder
    assert '"${#VERSION}" -gt 10' in builder


def test_qnap_builder_stages_a_versioned_shared_server_bundle(tmp_path: Path):
    distribution = tmp_path / "distribution"
    shutil.copytree(ROOT / "distribution" / "qnap", distribution / "qnap")
    shutil.copytree(ROOT / "distribution" / "server", distribution / "server")
    shutil.copytree(ROOT / "server" / "scripts", tmp_path / "server" / "scripts")
    fake_qbuild = tmp_path / "qbuild"
    fake_qbuild.write_text("""#!/bin/sh
set -eu
grep -q 'QPKG_VER=\"0.9.0\"' qpkg.cfg
test -f shared/ClearPocketServer.sh
test -f shared/server/compose.yaml
test -f shared/server/manage.py
test -f shared/server/tools/backup.sh
test -f shared/server/tools/restore.sh
test \"$(cat shared/server/VERSION)\" = \"0.9.0\"
mkdir -p build
: > build/ClearPocketServer_0.9.0.qpkg
""")
    fake_qbuild.chmod(0o755)
    subprocess.run([distribution / "qnap" / "build.sh", "0.9.0", fake_qbuild],
                   check=True, capture_output=True, text=True)
    assert (distribution / "qnap" / "build" / "ClearPocketServer_0.9.0.qpkg").is_file()


def manager_deployment(tmp_path: Path):
    (tmp_path / "compose.yaml").write_text("services: {}\n")
    contents = module.configuration(allowed_hosts="private.example", bind_address="0.0.0.0",
        port=8080, image="example/server", version="test",
        database_storage="customer_database", attachments_storage="/srv/private/attachments")
    (tmp_path / ".env").write_text(contents)
    return manager.deployment(tmp_path)


class RecordedRunner:
    def __init__(self, responses: list[tuple[int, str, str]] | None = None):
        self.commands: list[list[str]] = []
        self.responses = list(responses or [])

    def __call__(self, command, *, check=True):
        self.commands.append(list(command))
        returncode, stdout, stderr = self.responses.pop(0) if self.responses else (0, "", "")
        if check and returncode:
            raise manager.ManagerError(stderr or stdout)
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)


def test_manager_rejects_duplicate_or_incomplete_private_configuration(tmp_path: Path):
    (tmp_path / "compose.yaml").write_text("services: {}\n")
    (tmp_path / ".env").write_text("CLEARPOCKET_PORT=8080\nCLEARPOCKET_PORT=8081\n")
    with pytest.raises(manager.ManagerError, match="duplicate"):
        manager.deployment(tmp_path)
    (tmp_path / ".env").write_text("CLEARPOCKET_PORT=8080\n")
    with pytest.raises(manager.ManagerError, match="missing required"):
        manager.deployment(tmp_path)


def test_manager_accepts_external_private_configuration_but_rejects_symlinks(tmp_path: Path):
    (tmp_path / "compose.yaml").write_text("services: {}\n")
    private = tmp_path / "durable" / ".env"
    private.parent.mkdir()
    private.write_text(module.configuration(allowed_hosts="localhost", bind_address="127.0.0.1",
        port=8080, image="example/server", version="test"))
    assert manager.deployment(tmp_path, private).environment_file == private.resolve()
    link = tmp_path / ".env"
    link.symlink_to(private)
    with pytest.raises(manager.ManagerError, match="non-symlink"):
        manager.deployment(tmp_path, link)


def test_manager_start_validates_then_uses_compose_and_current_local_health(tmp_path: Path):
    target = manager_deployment(tmp_path)
    runner = RecordedRunner([(0, "27.0.0\n", ""), (0, "2.39.1\n", ""),
                             (0, "", ""), (0, "", "")])
    checked_urls: list[str] = []

    def healthy(url: str, timeout: float) -> bool:
        checked_urls.append(url)
        return True

    manager.start(target, runner=runner, health_check=healthy, timeout=1, pause=0)
    assert runner.commands[-1][-2:] == ["up", "-d"]
    assert any(command[-2:] == ["config", "--quiet"] for command in runner.commands)
    assert checked_urls == ["http://127.0.0.1:8080/api/v1/health"]
    assert all("down" not in command and "-v" not in command for command in runner.commands)


def test_manager_stop_is_data_preserving(tmp_path: Path):
    target = manager_deployment(tmp_path)
    runner = RecordedRunner()
    manager.stop(target, runner)
    assert runner.commands[0][-1] == "stop"
    assert "down" not in runner.commands[0]
    assert "-v" not in runner.commands[0]


def test_manager_backup_uses_bundled_coordinated_backup_and_explicit_target(tmp_path: Path):
    target = manager_deployment(tmp_path)
    tools = tmp_path / "tools"
    tools.mkdir()
    script = tools / "backup.sh"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    runner = RecordedRunner()
    destination = tmp_path / "private backups"
    manager.backup(target, destination, runner, project_name="customer-home")
    assert runner.commands == [[str(script), "--env-file", str(tmp_path / ".env"),
                                "--project-name", "customer-home", str(destination)]]
    with pytest.raises(manager.ManagerError, match="project name"):
        manager.backup(target, destination, runner, project_name="unsafe target")


def test_manager_accepts_array_and_line_delimited_compose_status(tmp_path: Path):
    target = manager_deployment(tmp_path)
    array = RecordedRunner([(0, '[{"Service":"api","State":"running","Health":"healthy"}]', "")])
    assert manager.compose_services(target, array)[0]["Service"] == "api"
    lines = RecordedRunner([(0, '{"Service":"api","State":"running"}\n'
        '{"Service":"database","State":"running"}\n', "")])
    assert [item["Service"] for item in manager.compose_services(target, lines)] == ["api", "database"]


def test_manager_diagnostics_are_allowlisted_and_never_contain_secrets_or_paths(tmp_path: Path, monkeypatch):
    target = manager_deployment(tmp_path)
    runner = RecordedRunner([
        (0, "27.0.0\n", ""), (0, "2.39.1\n", ""), (0, "", ""),
        (0, '[{"Service":"api","State":"running","Health":"healthy",'
            '"Env":"BUDGET_APP_JWT_SECRET=leaked","Mounts":"/srv/private/attachments"}]', ""),
    ])
    monkeypatch.setattr(manager, "health", lambda _url: True)
    destination = manager.diagnostics(target, tmp_path / "support.json", runner)
    contents = destination.read_text()
    report = json.loads(contents)
    assert report["attachment_storage"] == "host-directory"
    assert report["database_storage"] == "docker-volume"
    assert report["operations_storage"] == "docker-volume"
    assert report["health"] == "healthy"
    assert report["services"] == [{"service": "api", "state": "running", "health": "healthy"}]
    for secret in manager.SECRET_KEYS:
        assert target.environment[secret] not in contents
    assert "private.example" not in contents
    assert "/srv/private/attachments" not in contents
    assert "leaked" not in contents
