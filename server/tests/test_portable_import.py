from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sqlite3
import tarfile

from fastapi.testclient import TestClient
import pytest

from app.config import Settings
from app.database import Base
from app.main import create_app
from scripts.local_server import LocalServerConfiguration, backup_status, migrate
from scripts.portable_archive import stage_portable_payload
import scripts.portable_import as portable_import_module
from scripts.portable_import import (
    import_payload, import_portable_archive, import_portable_archive_into_server,
    PortableImportError,
)
from scripts.portable_import import SECTION_TABLE_ORDER
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


SERVER_ROOT = Path(__file__).parents[1]


def test_portable_import_cli_reads_server_owner_credentials_from_stdin(
    tmp_path, monkeypatch, capsys
):
    archive = tmp_path / "household.tar.gz.age"
    archive.write_bytes(b"encrypted")
    captured: dict[str, object] = {}

    def import_server(source: Path, password: str) -> None:
        captured.update(source=source, password=password)

    monkeypatch.setattr(
        portable_import_module, "import_portable_archive_into_server", import_server
    )
    monkeypatch.setattr(
        portable_import_module.sys,
        "stdin",
        io.StringIO("private-owner-password\nprivate-owner-password\n"),
    )

    result = portable_import_module.main([
        str(archive), "--server-environment", "--owner-password-stdin",
    ])

    assert result == 0
    assert captured == {"source": archive, "password": "private-owner-password"}
    output = capsys.readouterr()
    assert "private-owner-password" not in output.out
    assert "private-owner-password" not in output.err


def test_portable_import_cli_rejects_mismatched_stdin_credentials(
    tmp_path, monkeypatch, capsys
):
    archive = tmp_path / "household.tar.gz.age"
    archive.write_bytes(b"encrypted")
    called = False

    def import_server(source: Path, password: str) -> None:
        nonlocal called
        called = True

    monkeypatch.setattr(
        portable_import_module, "import_portable_archive_into_server", import_server
    )
    monkeypatch.setattr(
        portable_import_module.sys,
        "stdin",
        io.StringIO("first-owner-password\nsecond-owner-password\n"),
    )

    result = portable_import_module.main([
        str(archive), "--server-environment", "--owner-password-stdin",
    ])

    assert result == 1
    assert called is False
    output = capsys.readouterr()
    assert "confirmation does not match" in output.err
    assert "first-owner-password" not in output.err
    assert "second-owner-password" not in output.err


class ExportTransport:
    def __init__(self, payload: dict, attachments: dict[str, bytes] | None = None):
        self.payload = payload
        self.attachments = attachments or {}

    def json(self, path: str) -> dict:
        return json.loads(json.dumps(self.payload))

    def bytes(self, path: str) -> bytes:
        return self.attachments[path.rsplit("/", 1)[-1]]


def test_portable_import_mapping_covers_every_transferable_table():
    mapped_tables = {table for _, table in SECTION_TABLE_ORDER}
    assert mapped_tables == set(Base.metadata.tables) - {
        "setup_state", "refresh_sessions", "pairing_codes",
    }


def test_portable_import_creates_separate_login_capable_authority_with_exact_money(
    tmp_path, client, owner_token, session_factory, monkeypatch
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    income = client.post(f"{root}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "amount_minor": 50_000,
        "occurred_on": "2026-09-01", "payee_name": "Employer",
    })
    assert income.status_code == 201
    transaction = client.post(f"{root}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"],
        "amount_minor": -12_345, "occurred_on": "2026-09-27", "payee_name": "Market",
        "client_operation_id": "de88e677-f171-45eb-8901-4cba956efda8",
    })
    assert transaction.status_code == 201
    attachment_content = b"\x89PNG\r\n\x1a\nportable import receipt"
    attachment = client.post(
        f"{root}/transactions/{transaction.json()['id']}/attachments",
        headers={
            **auth(owner_token), "X-Attachment-Filename": "receipt.png",
            "X-Attachment-Content-Type": "image/png", "Content-Type": "application/octet-stream",
        },
        content=attachment_content,
    )
    assert attachment.status_code == 201
    assignment_body = {"month": "2026-09-01", "assigned_minor": 20_000,
                       "mutation_operation_id": "9b3d4468-e8b2-4631-bebd-0d3f94e40c10",
                       "expected_allocation_version": client.get(
                           f"{root}/months/2026-09-01", headers=auth(owner_token)
                       ).json()["allocation_version"]}
    assignment = client.put(
        f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
        json=assignment_body,
    )
    assert assignment.status_code == 200
    exported = client.get(f"{root}/export.json", headers=auth(owner_token))
    assert exported.status_code == 200
    payload = exported.json()
    extracted = tmp_path / "extracted"
    stage_portable_payload(
        ExportTransport(payload, {attachment.json()["id"]: attachment_content}),
        budget["id"], extracted,
    )

    destination = LocalServerConfiguration.load_or_create(tmp_path / "new-authority")
    migrate(destination, SERVER_ROOT)
    import_payload(payload | {"attachment_payloads_included": True}, extracted, destination, "new-owner-password")

    with sqlite3.connect(destination.database_path) as database:
        assert database.execute(
            "SELECT amount_minor FROM transactions WHERE id=?", (transaction.json()["id"],)
        ).fetchone() == (-12_345,)
        assert database.execute("SELECT COALESCE(SUM(amount_minor),0) FROM allocation_postings").fetchone() == (0,)
        assert database.execute("PRAGMA foreign_key_check").fetchall() == []
        for section, table in SECTION_TABLE_ORDER:
            value = payload.get(section, [])
            expected_count = len(value) if isinstance(value, list) else int(value is not None)
            assert database.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone() == (expected_count,), section
        assert database.execute("SELECT transaction_id FROM transaction_creation_receipts").fetchone() == (transaction.json()["id"],)

    with pytest.raises(PortableImportError, match="new empty authority"):
        import_payload(
            payload | {"attachment_payloads_included": True}, extracted, destination,
            "replacement-owner-password",
        )
    with sqlite3.connect(destination.database_path) as database:
        assert database.execute(
            "SELECT amount_minor FROM transactions WHERE id=?", (transaction.json()["id"],)
        ).fetchone() == (-12_345,)
        assert database.execute("SELECT COUNT(*) FROM budgets").fetchone() == (1,)

    owner = payload["user_directory"][0]
    imported_app = create_app(Settings(
        database_url=f"sqlite:///{destination.database_path}",
        jwt_secret=destination.jwt_secret,
        attachment_storage_path=str(destination.attachment_path),
        attachment_encryption_key=destination.attachment_encryption_key,
        allowed_hosts=("testserver",),
    ))
    with TestClient(imported_app) as imported_client:
        login = imported_client.post("/api/v1/auth/login", json={
            "email": owner["email"], "password": "new-owner-password",
        })
        assert login.status_code == 200, login.text
        token = login.json()["access_token"]
        replay = imported_client.post(f"{root}/transactions", headers=auth(token), json={
            "account_id": account["id"], "category_id": category["id"],
            "amount_minor": -12_345, "occurred_on": "2026-09-27", "payee_name": "Market",
            "client_operation_id": "de88e677-f171-45eb-8901-4cba956efda8",
        })
        assert replay.status_code == 201, replay.text
        assert replay.json()["id"] == transaction.json()["id"]
        assignment_replay = imported_client.put(
            f"{root}/categories/{category['id']}/assignment", headers=auth(token), json=assignment_body
        )
        assert assignment_replay.status_code == 200, assignment_replay.text
        restored_export = imported_client.get(f"{root}/export.json", headers=auth(token))
        assert restored_export.status_code == 200, restored_export.text
        for section in ("transaction_creation_receipts", "workspace_command_receipts",
                        "account_revisions", "budget_structure_revisions", "payee_revisions",
                        "allocation_operations", "allocation_postings"):
            original = sorted(payload[section], key=lambda row: json.dumps(row, sort_keys=True))
            restored = sorted(restored_export.json()[section], key=lambda row: json.dumps(row, sort_keys=True))
            assert restored == original, section
        budgets = imported_client.get("/api/v1/budgets", headers=auth(token))
        assert budgets.status_code == 200
        assert [item["id"] for item in budgets.json()] == [budget["id"]]
        transactions = imported_client.get(f"{root}/transactions", headers=auth(token))
        assert transactions.status_code == 200
        imported_by_id = {item["id"]: item for item in transactions.json()}
        assert imported_by_id[transaction.json()["id"]]["amount_minor"] == -12_345
        downloaded = imported_client.get(
            f"{root}/transactions/{transaction.json()['id']}/attachments/{attachment.json()['id']}",
            headers=auth(token),
        )
        assert downloaded.status_code == 200
        assert downloaded.content == attachment_content

    archive = tmp_path / "portable.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(extracted / "manifest.json", arcname="manifest.json", recursive=False)
        output.add(extracted / "data.json", arcname="data.json", recursive=False)
        output.add(extracted / "attachments", arcname="attachments", recursive=True)
    encrypted = tmp_path / "portable.tar.gz.age"
    encrypted.write_bytes(archive.read_bytes())
    tools = tmp_path / "tools"
    tools.mkdir()
    age = tools / "age"
    age.write_text(
        '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == "--output" ]]; then output="$2"; shift 2; elif [[ "$1" == "--decrypt" ]]; then shift; else input="$1"; shift; fi; done\ncp "$input" "$output"\n'
    )
    age.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}:{os.environ['PATH']}")
    published = tmp_path / "atomically-published-authority"

    imported = import_portable_archive(
        encrypted, published, SERVER_ROOT, "another-owner-password"
    )

    assert imported.data_directory == published
    imported_status = backup_status(imported)
    assert imported_status["last_restore_verification"]["source_provider"] == "portable_archive"
    with sqlite3.connect(imported.database_path) as database:
        assert database.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert database.execute("PRAGMA foreign_key_check").fetchall() == []

    server_target = LocalServerConfiguration.load_or_create(tmp_path / "empty-server-authority")
    migrate(server_target, SERVER_ROOT)
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", server_target.environment()["BUDGET_APP_DATABASE_URL"])
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", server_target.jwt_secret)
    monkeypatch.setenv("BUDGET_APP_ATTACHMENT_STORAGE_PATH", str(server_target.attachment_path))
    monkeypatch.setenv("BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY", server_target.attachment_encryption_key)
    monkeypatch.setenv("BUDGET_APP_RECOVERY_STATUS_PATH", str(server_target.recovery_status_path))
    import_portable_archive_into_server(
        encrypted, "server-owner-password",
    )
    with sqlite3.connect(server_target.database_path) as database:
        assert database.execute("SELECT COUNT(*) FROM budgets").fetchone() == (1,)
        assert database.execute(
            "SELECT amount_minor FROM transactions WHERE id=?", (transaction.json()["id"],)
        ).fetchone() == (-12_345,)
    assert backup_status(server_target)["last_restore_verification"]["source_provider"] == "portable_archive"
    with pytest.raises(PortableImportError, match="new empty authority"):
        import_portable_archive_into_server(
            encrypted, "server-owner-password",
        )
