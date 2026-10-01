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


def test_docker_installer_uses_immutable_image_without_host_python_and_never_overwrites():
    script = (ROOT / "distribution" / "server" / "install-docker.sh").read_text()
    assert script.startswith("#!/bin/sh\nset -eu\n")
    assert "command -v docker" in script
    assert "command -v python" not in script
    assert 'case "$VERSION" in \'\'|edge|' in script
    assert 'docker pull "$IMAGE"' in script
    assert '--entrypoint python "$IMAGE"' in script
    assert '--user "$USER_ID:$GROUP_ID"' in script
    assert '/bundle/configure.py --output /bundle/.env' in script
    assert '--bind-address 127.0.0.1' in script
    assert 'if [ ! -e "$ENV_FILE" ]' in script
    assert "Existing private configuration preserved" in script
    assert 'compose.yaml" config --quiet' in script
    assert 'compose.yaml" up -d' in script
    assert "urlopen('http://127.0.0.1:8080/api/v1/health'" in script
    assert "down -v" not in script and "docker volume rm" not in script


def test_docker_only_backup_is_coordinated_encrypted_bounded_and_user_owned():
    script = (ROOT / "distribution" / "server" / "backup-docker.sh").read_text()
    assert script.startswith("#!/bin/sh\nset -eu\n")
    assert "command -v python" not in script and "command -v age" not in script
    assert "BUDGET_APP_BACKUP_AGE_RECIPIENT" in script
    assert "clearpocket-recovery-key.txt" in script
    assert 'compose stop api' in script and 'compose start api' in script
    assert "pg_dump --clean --if-exists" in script
    assert "scripts/backup_archive.py create-manifest" in script
    assert "age --recipient" in script
    assert "scripts/backup_health.py healthy" in script
    assert ".clearpocket-backup.lock" in script
    assert "BUDGET_APP_BACKUP_RETENTION" in script
    assert "DROPBOX_CREDENTIALS" in script
    assert 'dropbox-docker.sh" publish' in script
    assert "record_status publication_failed" in script
    assert "backup_health.py publication_failed" in script
    assert 'budget-*.tar.gz.age' in script
    assert "chown '$USER_ID:$GROUP_ID'" in script
    assert "down -v" not in script and "docker volume rm" not in script


def test_docker_only_restore_is_guarded_transactional_and_health_gated():
    script = (ROOT / "distribution" / "server" / "restore-docker.sh").read_text()
    assert script.startswith("#!/bin/sh\nset -eu\n")
    assert "command -v python" not in script and "command -v age" not in script
    assert "Type RESTORE" in script
    assert ':/input/archive.age:ro' in script
    assert ':/input/identity.txt:ro' in script
    assert "extract-verified" in script
    assert "require_empty_restore.sql" in script
    assert script.count("assert_empty_destination") >= 3
    assert "DESTINATION_MUTATION_STARTED" in script
    assert ".env.restore-original" in script
    assert 'find /var/lib/budget-app/attachments -mindepth 1' in script
    assert 'psql --single-transaction --set ON_ERROR_STOP=on' in script
    assert "compose up -d --force-recreate api" in script
    assert "recovery-status.json" in script
    assert "API remains stopped for inspection" in script
    assert "down -v" not in script and "docker volume rm" not in script


def test_docker_dropbox_tool_uses_pinned_container_and_read_only_credentials():
    script = (ROOT / "distribution" / "server" / "dropbox-docker.sh").read_text()
    assert script.startswith("#!/bin/sh\nset -eu\n")
    assert "command -v python" not in script
    assert "publish|list|fetch" in script
    assert ':/run/secrets/dropbox.env:ro' in script
    assert ':/input/$ARCHIVE_NAME:ro' in script
    assert 'publish "/input/$ARCHIVE_NAME"' in script
    assert "--credentials-file /run/secrets/dropbox.env" in script
    assert "scripts/backup_destination.py publish" in script
    assert "scripts/backup_destination.py list" in script
    assert "scripts/backup_destination.py fetch-dropbox" in script
    assert "BUDGET_APP_DROPBOX_ACCESS_TOKEN=" not in script
    assert "down -v" not in script and "docker volume rm" not in script


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
    assert "Register-ScheduledTask" in script
    assert "New-ScheduledTaskPrincipal" in script
    assert "-RunLevel Limited" in script
    assert 'Unregister-ScheduledTask -TaskName "ClearPocket Server"' in script
    assert '-Operation Start' in script
    assert "function Import-ClearPocketLocalDevice" in script
    assert "function Import-ClearPocketPortableArchive" in script
    assert 'Type IMPORT to stop this server and verify the transfer' in script
    assert 'Test-Path -LiteralPath (Join-Path $package.FullName "manifest.json") -PathType Leaf' in script
    assert '[IO.FileAttributes]::ReparsePoint' in script
    assert '"stop", "api"' in script
    assert '"up", "-d", "database"' in script
    assert ':/import/package:ro' in script
    assert "scripts/local_device_transfer.py /tmp/local-device-package --server-environment" in script
    assert "The API remains stopped" in script
    assert '"8" { Import-ClearPocketLocalDevice }' in script
    assert '"15" { Import-ClearPocketPortableArchive }' in script
    assert "function Configure-ClearPocketDropboxBackup" in script
    assert "Read-Host $Prompt -AsSecureString" in script
    assert "Security.AccessControl.FileSystemAccessRule" in script
    assert 'Join-Path $PSScriptRoot "dropbox.env"' in script
    assert '"16" { Configure-ClearPocketDropboxBackup }' in script
    assert '"17" { Disable-ClearPocketDropboxBackup }' in script
    assert "remote backups remain" in script
    portable_section = script.split("function Import-ClearPocketPortableArchive", 1)[1].split("function Install-ClearPocketBackupSchedule", 1)[0]
    assert ":/import/archive.age:ro" in portable_section
    assert ":/import/identity.txt:ro" in portable_section
    assert "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/identity.txt" in portable_section
    assert "scripts/portable_import.py /tmp/archive.age --server-environment" in portable_section
    assert "The API remains stopped" in portable_section
    assert '"9" {' in script
    assert 'backup-windows.ps1' in script
    assert 'Create an encrypted server backup' in script
    assert 'restore-windows.ps1' in script
    assert 'Restore an encrypted backup into this empty server' in script
    assert "Install-ClearPocketBackupSchedule" in script
    assert "ClearPocket Server Backup" in script
    assert "New-ScheduledTaskTrigger -Daily" in script
    assert "-StartWhenAvailable" in script
    assert "-MultipleInstances IgnoreNew" in script
    assert "Remove-ClearPocketBackupSchedule" in script
    assert "Show-ClearPocketBackupSchedule" in script
    assert "Update-ClearPocketServer" in script
    assert "Type UPDATE" in script
    update_section = script.split("function Update-ClearPocketServer", 1)[1].split('if ($Operation -eq "Start")', 1)[0]
    backup_index = update_section.index('& $backupScript -EnvironmentFile $environmentFile')
    pull_index = update_section.index('& docker pull "${image}:$serverVersion"')
    pin_index = update_section.index('Move-Item -LiteralPath $temporary -Destination $environmentFile -Force')
    health_index = update_section.index("Start-ClearPocketServer")
    assert backup_index < pull_index < pin_index < health_index
    assert "automatic downgrade is disabled after migrations" in update_section
    task_section = script.split("function Install-ClearPocketAutoStart", 1)[1]
    assert "BUDGET_APP_DB_PASSWORD" not in task_section
    assert "BUDGET_APP_JWT_SECRET" not in task_section
    assert "BUDGET_APP_JWT_SECRET" not in script.split("function Write-ClearPocketDiagnostics", 1)[1]
    assert "down -v" not in script
    assert "docker volume rm" not in script


def test_windows_per_user_installer_preserves_authority_and_publishes_only_allowlisted_program_files():
    root = ROOT / "distribution" / "server"
    command = (root / "install-windows.cmd").read_text()
    installer = (root / "install-windows.ps1").read_text()
    launcher = (root / "start-windows.ps1").read_text()
    assert "install-windows.ps1" in command
    assert 'Programs\\ClearPocket Server' in installer
    assert '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' in installer
    assert '$requiredFiles = @(' in installer
    assert 'tools\\backup_archive.py' in installer
    assert 'tools\\require_empty_restore.sql' in installer
    assert 'Move-Item -LiteralPath $temporary -Destination $destination -Force' in installer
    assert 'Join-Path $installRoot ".env"' in installer
    assert 'Copy-Item -LiteralPath $source -Destination $temporary' in installer
    assert 'Copy-Item -LiteralPath $sourceRoot' not in installer
    assert "WScript.Shell" in installer
    assert 'GetFolderPath("Desktop")' in installer
    assert 'GetFolderPath("Programs")' in installer
    assert 'Start-Process -FilePath $manager' in installer
    assert 'Join-Path $env:LOCALAPPDATA "ClearPocket Server\\Data"' in launcher
    for forbidden in ("database", "attachments", "clearpocket-recovery-key.txt", "Backups"):
        assert f'"{forbidden}"' not in installer


def test_windows_backup_is_coordinated_encrypted_atomic_and_health_visible():
    script = (ROOT / "distribution" / "server" / "backup-windows.ps1").read_text()
    assert "BUDGET_APP_BACKUP_AGE_RECIPIENT" in script
    assert '[IO.FileShare]::None' in script
    assert "Another ClearPocket backup is already running" in script
    assert '[ValidateSet("Interactive", "Scheduled")]' in script
    assert "Scheduled backup requires an explicit destination folder" in script
    assert "BUDGET_APP_BACKUP_RETENTION" in script
    assert "Invoke-BackupRetention" in script
    assert "Select-Object -Skip $Retention" in script
    assert "FileAttributes]::ReparsePoint" in script
    assert "clearpocket-recovery-key.txt" in script
    assert "age-keygen" in script
    assert "Type USE to adopt it without replacing it" in script
    assert 'Add-EnvironmentSetting "BUDGET_APP_BACKUP_AGE_RECIPIENT" $recipient' in script
    assert 'Add-EnvironmentSetting "BUDGET_APP_BACKUP_AGE_IDENTITY"' not in script
    assert '"stop", "api"' in script
    assert "pg_dump --clean --if-exists --no-owner --no-privileges" in script
    assert "api:/var/lib/budget-app/attachments/." in script
    assert '"start", "api"' in script
    assert 'scripts/backup_archive.py", "create-manifest"' in script
    assert "age --recipient" in script
    assert "Move-Item -LiteralPath $partial -Destination $final" in script
    assert 'Join-Path $PSScriptRoot "dropbox.env"' in script
    assert "scripts/backup_destination.py publish" in script
    assert "--credentials-file /tmp/dropbox.env" in script
    assert "install -m 600 -o budget -g budget /input/dropbox.env" in script
    assert 'Save-BackupStatus "publication_failed" $final' in script
    assert "scripts/backup_health.py" in script
    assert '/input/$filename' in script
    assert "/var/lib/budget-app/operations/backup-status.json" in script
    assert "Remove-Item -LiteralPath $partial" in script
    assert "down -v" not in script
    assert "docker volume rm" not in script


def test_windows_restore_is_verified_empty_guarded_and_never_in_place():
    script = (ROOT / "distribution" / "server" / "restore-windows.ps1").read_text()
    assert "require_empty_restore.sql" in script
    assert "Type RESTORE to verify this backup" in script
    assert "extract-verified /restore/archive.tar.gz /restore/verified" in script
    assert 'Assert-EmptyRecoveryDestination $true' in script
    assert '"stop", "api"' in script
    assert 'Set-RecoveredAttachmentKey $recoveryLine' in script
    assert 'psql", "--single-transaction"' in script
    assert '"-f", $guardContainer, "-f", $databaseContainer' in script
    assert '"up", "-d", "--force-recreate", "api"' in script
    assert "/var/lib/budget-app/operations/recovery-status.json" in script
    assert "The API remains stopped for inspection" in script
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
    assert "server/scripts/backup_schedule.py" in workflow


def test_server_image_contains_portable_import_runtime_and_age_decryptor():
    dockerfile = (ROOT / "server" / "Dockerfile").read_text()
    assert "apt-get install --no-install-recommends -y age" in dockerfile
    assert "COPY scripts ./scripts" in dockerfile


def test_qnap_qpkg_source_uses_shared_compose_and_preserves_customer_authority():
    root = ROOT / "distribution" / "qnap"
    config = (root / "template" / "qpkg.cfg").read_text()
    routines = (root / "template" / "package_routines").read_text()
    service = (root / "template" / "shared" / "ClearPocketServer.sh").read_text()
    setup = (root / "template" / "shared" / "ClearPocketSetup.sh").read_text()
    backup = (root / "template" / "shared" / "ClearPocketBackup.sh").read_text()
    restore = (root / "template" / "shared" / "ClearPocketRestore.sh").read_text()
    builder = (root / "build.sh").read_text()
    assert 'QPKG_NAME="ClearPocketServer"' in config
    assert 'QPKG_SERVICE_PROGRAM="ClearPocketServer.sh"' in config
    assert "Container Station must be installed" in routines
    assert "ClearPocketSetup.sh" in routines
    assert "CLEARPOCKET_DATA_ROOT" in routines
    assert "PKG_MAIN_REMOVE" not in routines
    assert "CLEARPOCKET_DATA_ROOT" in service
    assert 'compose up -d' in service
    assert 'compose stop' in service
    assert 'compose ps' in service
    assert 'ClearPocketBackup.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT"' in service
    assert 'ClearPocketRestore.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT"' in service
    assert "explicit final argument RESTORE" in service
    assert "explicit final argument UPGRADE" in service
    assert "automatic downgrade is disabled after migrations" in service
    upgrade_section = service.split("upgrade_server()", 1)[1].split("find_crontab()", 1)[0]
    backup_index = upgrade_section.index('ClearPocketBackup.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT" || return 1')
    pull_index = upgrade_section.index('"$DOCKER" pull "$IMAGE:$VERSION"')
    pin_index = upgrade_section.index('mv "$TEMP_ENV" "$ENV_FILE"')
    health_index = upgrade_section.index('if ! compose up -d || ! wait_healthy')
    assert backup_index < pull_index < pin_index < health_index
    assert "install-backup-schedule" in service
    assert "remove-backup-schedule" in service
    assert "backup-schedule-status" in service
    assert "# ClearPocketServerBackup" in service
    assert "Create one successful manual backup before enabling the schedule" in service
    assert 'mv "$ORIGINAL" "$CRON_FILE"' in service
    assert "the prior crontab was restored" in service
    assert "verify-local-device" in service
    assert "import-local-device" in service
    assert "import-portable" in service
    assert "Portable import requires the explicit final argument IMPORT" in service
    portable_section = service.split("portable_archive()", 1)[1].split("upgrade_server()", 1)[0]
    assert ':/import/archive.age:ro' in portable_section
    assert ':/import/identity.txt:ro' in portable_section
    assert "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/identity.txt" in portable_section
    assert "scripts/portable_import.py /tmp/archive.age --server-environment" in portable_section
    assert "API did not become healthy and remains stopped" in portable_section
    assert '/share/*' in service
    assert ':/import/package:ro' in service
    assert "scripts/local_device_transfer.py /tmp/local-device-package" in service
    assert "--server-environment" in service
    assert 'compose stop api' in service
    assert 'compose up -d database' in service
    assert "wait_healthy" in service
    assert "urlopen('http://127.0.0.1:8080/api/v1/health'" in service
    assert "Imported authority committed, but the API did not become healthy" in service
    assert 'the API remains stopped' in service
    assert "down -v" not in service
    assert "docker volume rm" not in service
    assert "/dev/urandom" in setup
    assert "scripts/backup_archive.py create-manifest" in backup
    assert backup.startswith("#!/bin/sh\nset -eu\n")
    assert "scripts/backup_health.py healthy" in backup
    assert "age --recipient" in backup
    assert "qnap-backup.lock" in backup
    assert "BUDGET_APP_BACKUP_RETENTION" in backup
    assert 'DROPBOX_CREDENTIALS="$DATA_ROOT/dropbox.env"' in backup
    assert ':/run/secrets/dropbox.env:ro' in backup
    assert "scripts/backup_destination.py publish" in backup
    assert "record_status publication_failed" in backup
    assert "backup_health.py publication_failed" in backup
    assert "budget-*.tar.gz.age" in backup
    assert "apply_retention" in backup
    assert "compose stop api" in backup and "compose start api" in backup
    assert "down -v" not in backup and "docker volume rm" not in backup
    assert "extract-verified" in restore
    assert restore.startswith("#!/bin/sh\nset -eu\n")
    assert "require_empty_restore.sql" in restore
    assert "attachment-key-recovery.env" in restore
    assert "--force-recreate api" in restore
    assert "recovery-status.json" in restore
    assert ':/input/archive.age:ro' in restore
    assert ':/input/identity.txt:ro' in restore
    assert "Another QNAP recovery is already running" in restore
    assert "DESTINATION_MUTATION_STARTED" in restore
    assert ".env.restore-original" in restore
    assert "Could not remove recovery attachment staging" in restore
    assert 'find /var/lib/budget-app/attachments -mindepth 1' in restore
    assert "down -v" not in restore and "docker volume rm" not in restore
    assert "Existing private ClearPocket configuration preserved" in setup
    assert "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY" in setup
    assert "CLEARPOCKET_OPERATIONS_STORAGE" in setup
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
test -x shared/ClearPocketSetup.sh
test -x shared/ClearPocketBackup.sh
test -x shared/ClearPocketRestore.sh
test -f shared/server/compose.yaml
test -f shared/server/manage.py
test -f shared/server/tools/backup.sh
test -f shared/server/tools/restore.sh
test -f shared/server/tools/backup_schedule.py
test \"$(cat shared/server/VERSION)\" = \"0.9.0\"
mkdir -p build
: > build/ClearPocketServer_0.9.0.qpkg
""")
    fake_qbuild.chmod(0o755)
    subprocess.run([distribution / "qnap" / "build.sh", "0.9.0", fake_qbuild],
                   check=True, capture_output=True, text=True)
    assert (distribution / "qnap" / "build" / "ClearPocketServer_0.9.0.qpkg").is_file()


def test_qnap_first_run_generates_private_exact_secrets_and_never_overwrites(tmp_path: Path):
    package = tmp_path / "package"
    server = package / "server"
    server.mkdir(parents=True)
    setup = package / "ClearPocketSetup.sh"
    shutil.copy2(ROOT / "distribution" / "qnap" / "template" / "shared" / "ClearPocketSetup.sh", setup)
    setup.chmod(0o755)
    (server / "VERSION").write_text("0.9.0\n")
    share = tmp_path / "share"
    data = share / "Public" / "ClearPocketServer"
    environment = dict(os.environ, CLEARPOCKET_QNAP_SHARE_ROOT=str(share))

    first = subprocess.run([setup, data], env=environment, check=True, capture_output=True, text=True)
    private = data / ".env"
    values = parsed(private.read_text())
    assert values["CLEARPOCKET_SERVER_VERSION"] == "0.9.0"
    assert values["CLEARPOCKET_DATABASE_STORAGE"] == f"{data}/database"
    assert values["CLEARPOCKET_ATTACHMENTS_STORAGE"] == f"{data}/attachments"
    assert values["CLEARPOCKET_OPERATIONS_STORAGE"] == f"{data}/operations"
    assert len(values["BUDGET_APP_DB_PASSWORD"]) >= 36
    assert len(values["BUDGET_APP_JWT_SECRET"]) >= 48
    assert len(base64.urlsafe_b64decode(values["BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"])) == 32
    assert private.stat().st_mode & 0o777 == 0o600
    assert values["BUDGET_APP_DB_PASSWORD"] not in first.stdout
    original = private.read_bytes()

    second = subprocess.run([setup, data], env=environment, check=True, capture_output=True, text=True)
    assert private.read_bytes() == original
    assert "preserved" in second.stdout


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


def test_manager_restore_uses_bundled_verified_new_destination_flow(tmp_path: Path):
    target = manager_deployment(tmp_path)
    tools = tmp_path / "tools"
    tools.mkdir()
    script = tools / "restore.sh"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    archive = tmp_path / "budget recovery.tar.gz.age"
    archive.write_bytes(b"encrypted")
    runner = RecordedRunner()

    manager.restore(target, archive, runner, project_name="customer-recovery")

    assert runner.commands == [[
        str(script), "--env-file", str(tmp_path / ".env"), "--yes",
        "--project-name", "customer-recovery", str(archive.resolve()),
    ]]
    with pytest.raises(manager.ManagerError, match="project name"):
        manager.restore(target, archive, runner, project_name="unsafe target")


def test_manager_restore_refuses_links_missing_archives_and_missing_tool(tmp_path: Path):
    target = manager_deployment(tmp_path)
    archive = tmp_path / "backup.age"
    archive.write_bytes(b"encrypted")
    with pytest.raises(manager.ManagerError, match="tools are missing"):
        manager.restore(target, archive, RecordedRunner())
    tools = tmp_path / "tools"
    tools.mkdir()
    (tools / "restore.sh").write_text("#!/bin/sh\n")
    link = tmp_path / "backup-link.age"
    link.symlink_to(archive)
    runner = RecordedRunner()
    with pytest.raises(manager.ManagerError, match="non-symlink"):
        manager.restore(target, link, runner)
    with pytest.raises(manager.ManagerError, match="non-symlink"):
        manager.restore(target, tmp_path / "missing.age", runner)
    assert runner.commands == []


def upgrade_deployment(tmp_path: Path):
    target = manager_deployment(tmp_path)
    tools = tmp_path / "tools"
    tools.mkdir()
    script = tools / "backup.sh"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    (tmp_path / "VERSION").write_text("1.0.0\n")
    return target


def test_manager_upgrade_requires_backup_then_atomically_pins_and_health_checks_exact_image(tmp_path: Path):
    target = upgrade_deployment(tmp_path)
    original = manager.load_environment(target.environment_file)
    runner = RecordedRunner()
    version = manager.upgrade(
        target, tmp_path / "backups", runner=runner,
        health_check=lambda _url, _timeout: True, project_name="customer-home", timeout=1,
    )
    assert version == "1.0.0"
    updated = manager.load_environment(target.environment_file)
    assert updated["CLEARPOCKET_SERVER_VERSION"] == "1.0.0"
    for secret in manager.SECRET_KEYS:
        assert updated[secret] == original[secret]
    backup_index = next(index for index, command in enumerate(runner.commands)
                        if command[0].endswith("backup.sh"))
    pull_index = runner.commands.index(["docker", "pull", "example/server:1.0.0"])
    up_index = next(index for index, command in enumerate(runner.commands)
                    if command[-2:] == ["up", "-d"])
    assert backup_index < pull_index < up_index
    assert not list(tmp_path.glob("..env.*.update"))


def test_manager_upgrade_pull_failure_leaves_private_version_unchanged(tmp_path: Path):
    target = upgrade_deployment(tmp_path)
    runner = RecordedRunner([
        (0, "27.0.0", ""), (0, "2.39.1", ""), (0, "", ""),
        (0, "", ""), (1, "", "image unavailable"),
    ])
    with pytest.raises(manager.ManagerError, match="image unavailable"):
        manager.upgrade(target, tmp_path / "backups", runner=runner)
    assert manager.load_environment(target.environment_file)["CLEARPOCKET_SERVER_VERSION"] == "test"


def test_manager_upgrade_never_auto_downgrades_after_unhealthy_migration(tmp_path: Path):
    target = upgrade_deployment(tmp_path)
    with pytest.raises(manager.ManagerError, match="Automatic image rollback is intentionally disabled"):
        manager.upgrade(target, tmp_path / "backups", runner=RecordedRunner(),
                        health_check=lambda _url, _timeout: False, timeout=0.001)
    assert manager.load_environment(target.environment_file)["CLEARPOCKET_SERVER_VERSION"] == "1.0.0"


def test_manager_portable_import_stops_api_uses_read_only_archive_and_restarts_after_success(tmp_path: Path):
    target = manager_deployment(tmp_path)
    archive = tmp_path / "household export.age"
    archive.write_bytes(b"encrypted")
    identity = tmp_path / "age identity.txt"
    identity.write_text("AGE-SECRET-KEY-test\n")
    runner = RecordedRunner()
    interactive = RecordedRunner()
    manager.portable_import(
        target, archive, runner=runner, interactive_runner=interactive,
        health_check=lambda _url, _timeout: True, timeout=1, age_identity=identity,
    )
    stop = next(command for command in runner.commands if command[-2:] == ["stop", "api"])
    database = next(command for command in runner.commands if command[-3:] == ["up", "-d", "database"])
    assert runner.commands.index(stop) < runner.commands.index(database)
    assert len(interactive.commands) == 1
    command = interactive.commands[0]
    assert f"{archive.resolve()}:/import/archive.age:ro" in command
    assert f"{identity.resolve()}:/import/age-identity.txt:ro" in command
    assert "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/age-identity.txt" in command
    assert "--user" in command and "root" in command
    assert command[-3:-1] == ["sh", "-c"]
    assert "install -m 600 -o budget -g budget /import/archive.age /tmp/archive.age" in command[-1]
    assert "exec su -s /bin/sh budget" in command[-1]
    assert "python scripts/portable_import.py /tmp/archive.age --server-environment" in command[-1]
    assert any(item[-2:] == ["up", "-d"] for item in runner.commands)
    assert all("down" not in item and "-v" not in item for item in runner.commands)


def test_manager_portable_import_refuses_archive_symlink_before_docker(tmp_path: Path):
    target = manager_deployment(tmp_path)
    archive = tmp_path / "archive.age"
    archive.write_bytes(b"encrypted")
    link = tmp_path / "archive-link.age"
    link.symlink_to(archive)
    runner = RecordedRunner()
    with pytest.raises(manager.ManagerError, match="non-symlink"):
        manager.portable_import(target, link, runner=runner)
    assert runner.commands == []


def test_manager_local_device_verification_is_isolated_and_never_starts_database(tmp_path: Path):
    target = manager_deployment(tmp_path)
    package = tmp_path / "phone backup.clearpocketbackup"
    package.mkdir()
    (package / "manifest.json").write_text("{}")
    runner = RecordedRunner()
    interactive = RecordedRunner()
    manager.verify_local_device_backup(
        target, package, runner=runner, interactive_runner=interactive,
    )
    assert len(interactive.commands) == 1
    command = interactive.commands[0]
    assert f"{package.resolve()}:/import/package:ro" in command
    assert "scripts/local_device_transfer.py /tmp/local-device-package" in command[-1]
    assert "--user" in command and "root" in command
    assert all("up" not in item and "stop" not in item for item in runner.commands)
    assert all("down" not in item and "-v" not in item for item in runner.commands)


def test_manager_local_device_import_uses_empty_server_path_and_restarts_only_after_success(tmp_path: Path):
    target = manager_deployment(tmp_path)
    package = tmp_path / "phone backup.clearpocketbackup"
    package.mkdir()
    (package / "manifest.json").write_text("{}")
    runner = RecordedRunner()
    interactive = RecordedRunner()
    manager.local_device_import(
        target, package, runner=runner, interactive_runner=interactive,
        health_check=lambda _url, _timeout: True, timeout=1,
    )
    stop = next(command for command in runner.commands if command[-2:] == ["stop", "api"])
    database = next(command for command in runner.commands if command[-3:] == ["up", "-d", "database"])
    assert runner.commands.index(stop) < runner.commands.index(database)
    assert len(interactive.commands) == 1
    command = interactive.commands[0]
    assert f"{package.resolve()}:/import/package:ro" in command
    assert "alembic upgrade head" in command[-1]
    assert "scripts/local_device_transfer.py /tmp/local-device-package --server-environment" in command[-1]
    assert any(item[-2:] == ["up", "-d"] for item in runner.commands)
    assert all("down" not in item and "-v" not in item for item in runner.commands)


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
