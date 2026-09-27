from __future__ import annotations

import json
import os
from pathlib import Path
import sqlite3
import tarfile

from fastapi.testclient import TestClient

from app.config import Settings
from app.database import Base
from app.main import create_app
from scripts.local_server import LocalServerConfiguration, migrate
from scripts.portable_archive import stage_portable_payload
from scripts.portable_import import import_payload, import_portable_archive
from scripts.portable_import import SECTION_TABLE_ORDER
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


SERVER_ROOT = Path(__file__).parents[1]


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
    assert mapped_tables == set(Base.metadata.tables) - {"setup_state", "refresh_sessions"}


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
    assignment = client.put(
        f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 20_000},
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
    with sqlite3.connect(imported.database_path) as database:
        assert database.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert database.execute("PRAGMA foreign_key_check").fetchall() == []
