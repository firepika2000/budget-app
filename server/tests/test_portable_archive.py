from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tarfile

import pytest

from app.portable_data import FORMAT_NAME, FORMAT_VERSION, section_manifest
from scripts.portable_archive import (
    APITransport, PortableArchiveError, create_portable_archive, extract_and_validate_archive,
    stage_portable_payload,
)


class FakeTransport:
    def __init__(self, payload: dict, attachments: dict[str, bytes]):
        self.payload = payload
        self.attachments = attachments
        self.downloads: list[str] = []

    def json(self, path: str) -> dict:
        assert path.endswith("/export.json")
        return json.loads(json.dumps(self.payload))

    def bytes(self, path: str) -> bytes:
        self.downloads.append(path)
        return self.attachments[path.rsplit("/", 1)[-1]]


def payload_for(content: bytes) -> dict:
    sections = {
        "budget": {"id": "budget-1", "currency_code": "USD"},
        "transactions": [{"id": "transaction-1", "amount_minor": -123}],
        "transaction_attachments": [{
            "id": "attachment-1", "transaction_id": "transaction-1",
            "filename": "receipt.jpg", "content_type": "image/jpeg",
            "byte_count": len(content), "sha256": hashlib.sha256(content).hexdigest(),
            "detached_at": None,
        }],
    }
    return {
        "format": FORMAT_NAME, "schema_version": FORMAT_VERSION,
        "exported_at": "2026-09-27T00:00:00Z", "attachment_payloads_included": False,
        "section_manifest": section_manifest(sections), **sections,
    }


def test_portable_archive_stages_verified_data_and_attachment_payloads(tmp_path):
    content = b"\xff\xd8\xffportable receipt"
    transport = FakeTransport(payload_for(content), {"attachment-1": content})
    root = tmp_path / "payload"

    stage_portable_payload(transport, "budget-1", root)

    data = json.loads((root / "data.json").read_text())
    manifest = json.loads((root / "manifest.json").read_text())
    assert data["attachment_payloads_included"] is True
    assert (root / "attachments" / "attachment-1").read_bytes() == content
    assert manifest["data_sha256"] == hashlib.sha256((root / "data.json").read_bytes()).hexdigest()
    assert manifest["attachments"]["attachment-1"]["sha256"] == hashlib.sha256(content).hexdigest()
    assert len(transport.downloads) == 1


def test_portable_archive_refuses_tampered_attachment_without_leaving_payload(tmp_path):
    expected = b"\xff\xd8\xffexpected"
    transport = FakeTransport(payload_for(expected), {"attachment-1": b"\xff\xd8\xfftampered"})

    with pytest.raises(PortableArchiveError, match="integrity"):
        stage_portable_payload(transport, "budget-1", tmp_path / "payload")


def test_portable_archive_encrypts_to_no_overwrite_generation(tmp_path, monkeypatch):
    tools = tmp_path / "tools"
    tools.mkdir()
    age = tools / "age"
    age.write_text(
        '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == "--output" ]]; then output="$2"; shift 2; elif [[ "$1" == "--recipient" ]]; then shift 2; else input="$1"; shift; fi; done\nprintf "age-encryption.org/v1\\n" > "$output"\ncat "$input" >> "$output"\n'
    )
    age.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}:{os.environ['PATH']}")
    monkeypatch.setenv("BUDGET_APP_BACKUP_AGE_RECIPIENT", "age1test")
    transport = FakeTransport(payload_for(b"\xff\xd8\xffreceipt"), {"attachment-1": b"\xff\xd8\xffreceipt"})

    result = create_portable_archive(transport, "budget-1", tmp_path / "exports")

    assert result.name.startswith("budget-portable-")
    assert result.read_bytes().startswith(b"age-encryption.org/v1\n")
    assert result.stat().st_mode & 0o777 == 0o600


def test_remote_plaintext_server_is_refused():
    with pytest.raises(PortableArchiveError, match="HTTPS"):
        APITransport("http://budget.example.test", "token")


def test_detached_attachment_metadata_is_preserved_without_downloading_payload(tmp_path):
    content = b"\xff\xd8\xffreceipt"
    payload = payload_for(content)
    payload["transaction_attachments"][0]["detached_at"] = "2026-09-27T00:00:00Z"
    payload["section_manifest"] = section_manifest({
        key: value for key, value in payload.items()
        if key not in {"format", "schema_version", "exported_at", "attachment_payloads_included", "section_manifest"}
    })
    transport = FakeTransport(payload, {"attachment-1": content})

    stage_portable_payload(transport, "budget-1", tmp_path / "payload")

    assert transport.downloads == []
    assert not (tmp_path / "payload" / "attachments" / "attachment-1").exists()


def test_extracted_archive_requires_exact_payload_coverage_and_validates_all_hashes(tmp_path):
    content = b"\xff\xd8\xffreceipt"
    root = tmp_path / "payload"
    stage_portable_payload(
        FakeTransport(payload_for(content), {"attachment-1": content}), "budget-1", root
    )
    archive = tmp_path / "portable.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(root / "manifest.json", arcname="manifest.json", recursive=False)
        output.add(root / "data.json", arcname="data.json", recursive=False)
        output.add(root / "attachments", arcname="attachments", recursive=True)

    payload = extract_and_validate_archive(archive, tmp_path / "verified")

    assert payload["budget"]["id"] == "budget-1"
    assert (tmp_path / "verified" / "attachments" / "attachment-1").read_bytes() == content


def test_archive_extraction_rejects_unsafe_member_before_writing_outside_staging(tmp_path):
    source = tmp_path / "secret"
    source.write_text("must stay contained")
    archive = tmp_path / "unsafe.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(source, arcname="../outside")

    with pytest.raises(PortableArchiveError, match="unsafe member"):
        extract_and_validate_archive(archive, tmp_path / "verified")
    assert not (tmp_path / "outside").exists()
