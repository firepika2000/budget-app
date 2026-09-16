from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tarfile


SERVER_ROOT = Path(__file__).parents[1]
BACKUP = SERVER_ROOT / "scripts" / "backup.sh"
RESTORE = SERVER_ROOT / "scripts" / "restore.sh"


def _archive(
    tmp_path: Path, *, corrupt: bool = False, omit_key: bool = False,
    format_version: int = 1,
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
            "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=test-key\n"
        )
    (attachments / "object-1").write_bytes(b"encrypted-object")
    files = [contents / "BACKUP-METADATA", contents / "database.sql", attachments / "object-1"]
    if not omit_key:
        files.insert(1, contents / "attachment-key-recovery.env")
    manifest = []
    for item in files:
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
        '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FAKE_DOCKER_LOG"\ncat >/dev/null\n'
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
    assert len(calls) == 4
    assert all("--project-name budget-recovery" in call for call in calls)
    assert "exec -T database psql --set ON_ERROR_STOP=on" in calls[0]
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
