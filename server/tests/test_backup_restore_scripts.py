from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile

import pytest


SERVER_ROOT = Path(__file__).parents[1]
BACKUP = SERVER_ROOT / "scripts" / "backup.sh"
RESTORE = SERVER_ROOT / "scripts" / "restore.sh"
ARCHIVE_TOOL = SERVER_ROOT / "scripts" / "backup_archive.py"


def _archive(
    tmp_path: Path, *, corrupt: bool = False, omit_key: bool = False,
    format_version: int = 1,
    recovery_key: str = "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=test-key\n",
    omit_digest_for: str | None = None,
) -> Path:
    contents = tmp_path / "contents"
    attachments = contents / "attachments"
    attachments.mkdir(parents=True)
    (contents / "database.sql").write_text("SELECT 1;\n")
    (contents / "BACKUP-METADATA").write_text(
        f"format_version={format_version}\ncreated_at=2026-09-16T00:00:00Z\n"
        "database_revision=0021_scheduled_payee_id\n"
    )
    if not omit_key:
        (contents / "attachment-key-recovery.env").write_text(
            recovery_key
        )
    (attachments / "object-1").write_bytes(b"encrypted-object")
    files = [contents / "BACKUP-METADATA", contents / "database.sql", attachments / "object-1"]
    if not omit_key:
        files.insert(1, contents / "attachment-key-recovery.env")
    manifest = []
    for item in files:
        if str(item.relative_to(contents)) == omit_digest_for:
            continue
        digest = hashlib.sha256(item.read_bytes()).hexdigest()
        if corrupt and item.name == "database.sql":
            digest = "0" * 64
        manifest.append(f"{digest}  {item.relative_to(contents)}")
    (contents / "MANIFEST.sha256").write_text("\n".join(manifest) + "\n")
    archive = tmp_path / "backup.tar.gz.age"
    with tarfile.open(archive, "w:gz") as tar:
        for item in contents.iterdir():
            tar.add(item, arcname=item.name)
    return archive


def _environment(tmp_path: Path) -> tuple[dict[str, str], Path]:
    tools = tmp_path / "tools"
    tools.mkdir()
    log = tmp_path / "docker.log"
    age = tools / "age"
    age.write_text('#!/usr/bin/env bash\ncat "${@: -1}"\n')
    docker = tools / "docker"
    docker.write_text(
        '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FAKE_DOCKER_LOG"\n'
        'if [[ "$*" == *BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY* ]]; then\n'
        '  printf "%s\\n" "${RESTORE_TEST_KEY:-BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=test-key}"\n'
        'else cat >/dev/null; fi\n'
    )
    age.chmod(0o755)
    docker.chmod(0o755)
    environment = dict(os.environ)
    environment["PATH"] = f"{tools}:{environment['PATH']}"
    environment["FAKE_DOCKER_LOG"] = str(log)
    return environment, log


def _backup_environment(tmp_path: Path) -> tuple[dict[str, str], Path]:
    tools = tmp_path / "backup-tools"
    tools.mkdir()
    log = tmp_path / "backup-docker.log"
    (tools / "docker").write_text(
        """#!/usr/bin/env bash
printf "%s\\n" "$*" >> "$FAKE_DOCKER_LOG"
if [[ "$*" == *"exec -T database pg_dump"* ]]; then
  printf 'CREATE TABLE restored (id integer);\\n'
elif [[ "$*" == *"SELECT version_num FROM alembic_version"* ]]; then
  printf '0021_scheduled_payee_id\\n'
elif [[ "$*" == *"cp api:/var/lib/budget-app/attachments/."* ]]; then
  destination="${@: -1}"
  mkdir -p "$destination"
  printf 'encrypted-object' > "${destination%/}/object-1"
elif [[ "$*" == *"exec -T api sh -c"* ]]; then
  printf 'BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=test-key\\n'
fi
"""
    )
    (tools / "age").write_text(
        """#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then output="$2"; shift 2; else shift; fi
done
cat > "$output"
if [[ "${BACKUP_TEST_FAIL_AGE:-}" == "1" ]]; then exit 1; fi
"""
    )
    for tool in tools.iterdir():
        tool.chmod(0o755)
    environment = dict(os.environ)
    environment["PATH"] = f"{tools}:{environment['PATH']}"
    environment["FAKE_DOCKER_LOG"] = str(log)
    return environment, log


def test_restore_requires_an_explicit_compose_project_target(tmp_path):
    archive = _archive(tmp_path)
    result = subprocess.run(
        [str(RESTORE), "--yes", str(archive)],
        text=True, capture_output=True,
    )
    assert result.returncode == 2
    assert "explicit Docker Compose project name is required" in result.stderr


def test_backup_targets_named_project_and_archives_database_objects_key_and_manifest(tmp_path):
    environment, log = _backup_environment(tmp_path)
    output = tmp_path / "backups"
    result = subprocess.run(
        [str(BACKUP), "--project-name", "budget-source", str(output)],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    calls = log.read_text().splitlines()
    assert len(calls) == 4
    assert all("--project-name budget-source" in call for call in calls)
    archives = list(output.glob("budget-*.tar.gz.age"))
    assert len(archives) == 1
    with tarfile.open(archives[0], "r:gz") as tar:
        names = set(tar.getnames())
        assert {"BACKUP-METADATA", "database.sql", "attachment-key-recovery.env", "MANIFEST.sha256"} <= names
        assert any(name.endswith("attachments/object-1") for name in names)


def test_restore_verifies_archive_before_addressing_explicit_target(tmp_path):
    archive = _archive(tmp_path)
    environment, log = _environment(tmp_path)
    result = subprocess.run(
        [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    calls = log.read_text().splitlines()
    assert len(calls) == 5
    assert all("--project-name budget-recovery" in call for call in calls)
    assert "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY" in calls[0]
    assert "exec -T database psql --single-transaction --set ON_ERROR_STOP=on" in calls[1]
    assert "restart api" in calls[-1]


def test_corrupt_or_incomplete_backup_never_reaches_restore_target(tmp_path):
    environment, log = _environment(tmp_path)
    for archive in (
        _archive(tmp_path / "corrupt", corrupt=True),
        _archive(tmp_path / "incomplete", omit_key=True),
        _archive(tmp_path / "future-format", format_version=99),
    ):
        result = subprocess.run(
            [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
            env=environment, text=True, capture_output=True,
        )
        assert result.returncode != 0
    assert not log.exists(), "integrity and completeness checks must run before Docker mutation"


def test_restore_refuses_wrong_destination_key_before_mutating_database_or_objects(tmp_path):
    archive = _archive(tmp_path)
    environment, log = _environment(tmp_path)
    environment["RESTORE_TEST_KEY"] = "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=wrong-destination-secret"
    result = subprocess.run(
        [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "key does not match" in result.stderr
    assert "wrong-destination-secret" not in result.stderr + result.stdout
    calls = log.read_text().splitlines()
    assert len(calls) == 1
    assert "psql" not in calls[0]
    assert "restart" not in calls[0]


def test_restore_rejects_invalid_recovery_material_without_addressing_target(tmp_path):
    environment, log = _environment(tmp_path)
    for index, value in enumerate(("BUDGET_APP_JWT_SECRET=\n", "OTHER_KEY=secret\n", "BUDGET_APP_JWT_SECRET=secret\nUNEXPECTED=value\n")):
        archive = _archive(tmp_path / str(index), recovery_key=value)
        result = subprocess.run(
            [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
            env=environment, text=True, capture_output=True,
        )
        assert result.returncode != 0
        assert "recovery material is invalid" in result.stderr
    assert not log.exists()


def test_restore_accepts_matching_legacy_secret_without_exposing_it(tmp_path):
    key = "BUDGET_APP_JWT_SECRET=legacy-recovery-secret"
    archive = _archive(tmp_path, recovery_key=key + "\n")
    environment, _ = _environment(tmp_path)
    environment["RESTORE_TEST_KEY"] = key
    result = subprocess.run(
        [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "legacy-recovery-secret" not in result.stdout + result.stderr


def test_restore_rejects_unverified_archive_members_before_contacting_destination(tmp_path):
    environment, log = _environment(tmp_path)
    for index, member in enumerate(("database.sql", "attachment-key-recovery.env", "attachments/object-1")):
        archive = _archive(tmp_path / str(index), omit_digest_for=member)
        result = subprocess.run(
            [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
            env=environment, text=True, capture_output=True,
        )
        assert result.returncode != 0, f"Unverified {member} must never reach a recovery destination"
    assert not log.exists()


@pytest.mark.parametrize("kind", ["parent", "absolute", "symlink", "hardlink", "device", "duplicate"])
def test_restore_rejects_unsafe_tar_members_before_extracting_or_contacting_target(tmp_path, kind):
    archive = _archive(tmp_path)
    environment, log = _environment(tmp_path)
    outside = tmp_path / "outside"
    outside.write_bytes(b"untouched")
    with tarfile.open(archive, "r:gz") as source:
        entries = [(item, source.extractfile(item).read() if item.isfile() else None) for item in source]
    member = tarfile.TarInfo("attachments/unsafe")
    content = b"malicious"
    if kind == "parent": member.name = "../outside"
    elif kind == "absolute": member.name = str(outside)
    elif kind == "symlink": member.type = tarfile.SYMTYPE; member.linkname = str(outside)
    elif kind == "hardlink": member.type = tarfile.LNKTYPE; member.linkname = "database.sql"
    elif kind == "device": member.type = tarfile.CHRTYPE
    elif kind == "duplicate": member.name = "database.sql"
    member.size = len(content) if member.isfile() else 0
    with tarfile.open(archive, "w:gz") as output:
        for item, data in entries:
            output.addfile(item, io.BytesIO(data) if data is not None else None)
        output.addfile(member, io.BytesIO(content) if member.isfile() else None)
    result = subprocess.run(
        [str(RESTORE), "--yes", "--project-name", "budget-recovery", str(archive)],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "Unsafe backup member" in result.stderr or "Duplicate backup member" in result.stderr
    assert outside.read_bytes() == b"untouched"
    assert not log.exists()


def test_manifest_creation_covers_nested_and_hidden_objects_without_fallback(tmp_path):
    _archive(tmp_path)
    root = tmp_path / "contents"
    nested = root / "attachments" / "nested"
    nested.mkdir()
    (nested / "another-object").write_bytes(b"nested encrypted object")
    (root / "attachments" / ".hidden-object").write_bytes(b"hidden encrypted object")
    result = subprocess.run([sys.executable, str(ARCHIVE_TOOL), "create-manifest", str(root)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    entries = dict(line.split("  ", 1)[::-1] for line in (root / "MANIFEST.sha256").read_text().splitlines())
    expected = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in root.rglob("*") if path.is_file() and path.name != "MANIFEST.sha256"}
    assert entries == expected
    outside = tmp_path / "private-key"
    outside.write_text("must-not-be-archived")
    (root / "attachments" / "linked").symlink_to(outside)
    denied = subprocess.run([sys.executable, str(ARCHIVE_TOOL), "create-manifest", str(root)], text=True, capture_output=True)
    assert denied.returncode != 0
    assert "must-not-be-archived" not in denied.stdout + denied.stderr


def test_extraction_never_overwrites_existing_staging_data(tmp_path):
    archive = _archive(tmp_path)
    destination = tmp_path / "nonempty"
    destination.mkdir()
    existing = destination / "database.sql"
    existing.write_text("keep")
    result = subprocess.run([sys.executable, str(ARCHIVE_TOOL), "extract-verified", str(archive), str(destination)], text=True, capture_output=True)
    assert result.returncode != 0
    assert existing.read_text() == "keep"


def test_failed_encryption_never_publishes_a_completed_backup(tmp_path):
    environment, _ = _backup_environment(tmp_path)
    environment["BACKUP_TEST_FAIL_AGE"] = "1"
    output = tmp_path / "backups"
    result = subprocess.run([str(BACKUP), "--project-name", "budget-source", str(output)],
                            env=environment, text=True, capture_output=True)
    assert result.returncode != 0
    assert list(output.iterdir()) == []
    assert "Backup complete:" not in result.stdout


def test_backup_publication_refuses_to_overwrite_existing_archive(tmp_path):
    environment, _ = _backup_environment(tmp_path)
    fixed_date = tmp_path / "backup-tools" / "date"
    fixed_date.write_text("#!/usr/bin/env bash\nprintf '20260918T000000Z\\n'\n")
    fixed_date.chmod(0o755)
    output = tmp_path / "backups"
    command = [str(BACKUP), "--project-name", "budget-source", str(output)]
    first = subprocess.run(command, env=environment, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    archive = output / "budget-20260918T000000Z.tar.gz.age"
    before = archive.read_bytes()
    second = subprocess.run(command, env=environment, text=True, capture_output=True)
    assert second.returncode != 0
    assert archive.read_bytes() == before
    assert list(output.iterdir()) == [archive]
    assert "Backup complete:" not in second.stdout
