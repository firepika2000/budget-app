#!/usr/bin/env python3
"""Create an encrypted, provider-neutral Budget data archive through the production API."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from typing import Protocol
from urllib import error, parse, request

from app.portable_data import FORMAT_NAME, FORMAT_VERSION, canonical_json, validate_section_manifest


MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
METADATA_KEYS = {
    "format", "schema_version", "exported_at", "attachment_payloads_included", "section_manifest"
}


class PortableArchiveError(RuntimeError):
    pass


class PortableTransport(Protocol):
    def json(self, path: str) -> dict: ...
    def bytes(self, path: str) -> bytes: ...


class APITransport:
    def __init__(self, server_url: str, token: str):
        parsed = parse.urlparse(server_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path.rstrip("/"):
            raise PortableArchiveError("Server URL must contain only an http(s) origin")
        if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise PortableArchiveError("Remote portable export requires HTTPS")
        if not token.strip():
            raise PortableArchiveError("BUDGET_APP_ACCESS_TOKEN is required")
        self.server_url = server_url.rstrip("/")
        self.token = token

    def _open(self, path: str):
        value = request.Request(
            f"{self.server_url}/{path.lstrip('/')}",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        try:
            return request.urlopen(value, timeout=60)
        except error.HTTPError as failure:
            # Do not echo a response body which could contain financial data.
            raise PortableArchiveError(f"Budget Server refused portable export ({failure.code})") from failure
        except error.URLError as failure:
            raise PortableArchiveError(f"Budget Server connection failed: {failure.reason}") from failure

    def json(self, path: str) -> dict:
        with self._open(path) as response:
            if int(response.headers.get("Content-Length", "0") or 0) > 256 * 1024 * 1024:
                raise PortableArchiveError("Portable data export exceeds the supported size")
            value = json.load(response)
        if not isinstance(value, dict):
            raise PortableArchiveError("Portable data export is not a JSON object")
        return value

    def bytes(self, path: str) -> bytes:
        with self._open(path) as response:
            value = response.read(MAX_ATTACHMENT_BYTES + 1)
        if len(value) > MAX_ATTACHMENT_BYTES:
            raise PortableArchiveError("Attachment exceeds the supported 10 MB limit")
        return value


def _safe_id(value: object) -> str:
    text = str(value)
    if not text or len(text) > 100 or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for character in text):
        raise PortableArchiveError("Portable data contains an unsafe identifier")
    return text


def stage_portable_payload(transport: PortableTransport, budget_id: str, root: Path) -> None:
    budget_id = _safe_id(budget_id)
    payload = transport.json(f"api/v1/budgets/{budget_id}/export.json")
    if payload.get("format") != FORMAT_NAME or payload.get("schema_version") != FORMAT_VERSION:
        raise PortableArchiveError("Budget Server returned an unsupported portable data version")
    manifest = payload.get("section_manifest")
    if not isinstance(manifest, dict):
        raise PortableArchiveError("Portable data section manifest is missing")
    sections = {key: value for key, value in payload.items() if key not in METADATA_KEYS}
    try:
        validate_section_manifest(sections, manifest)
    except ValueError as failure:
        raise PortableArchiveError(str(failure)) from failure

    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    attachments_directory = root / "attachments"
    attachments_directory.mkdir(mode=0o700)
    attachment_manifest: dict[str, dict[str, object]] = {}
    for item in sections.get("transaction_attachments", []):
        if not isinstance(item, dict) or item.get("detached_at") is not None:
            continue
        attachment_id = _safe_id(item.get("id"))
        transaction_id = _safe_id(item.get("transaction_id"))
        content = transport.bytes(
            f"api/v1/budgets/{budget_id}/transactions/{transaction_id}/attachments/{attachment_id}"
        )
        digest = hashlib.sha256(content).hexdigest()
        if digest != item.get("sha256") or len(content) != item.get("byte_count"):
            raise PortableArchiveError(f"Attachment failed integrity validation: {attachment_id}")
        target = attachments_directory / attachment_id
        target.write_bytes(content)
        os.chmod(target, 0o600)
        attachment_manifest[attachment_id] = {
            "byte_count": len(content), "sha256": digest,
            "filename": item.get("filename"), "content_type": item.get("content_type"),
        }

    payload["attachment_payloads_included"] = True
    data = canonical_json(payload)
    (root / "data.json").write_bytes(data)
    os.chmod(root / "data.json", 0o600)
    archive_manifest = {
        "format": "budget-app-portable-archive",
        "format_version": 1,
        "data_sha256": hashlib.sha256(data).hexdigest(),
        "attachments": attachment_manifest,
    }
    (root / "manifest.json").write_bytes(canonical_json(archive_manifest))
    os.chmod(root / "manifest.json", 0o600)


def _encrypt(source: Path, destination: Path) -> None:
    executable = shutil.which("age")
    if not executable:
        raise PortableArchiveError("age is required for encrypted portable archives")
    command = [executable]
    recipient = os.environ.get("BUDGET_APP_BACKUP_AGE_RECIPIENT", "").strip()
    if recipient:
        command += ["--recipient", recipient]
    else:
        command += ["--passphrase"]
    command += ["--output", str(destination), str(source)]
    if subprocess.run(command).returncode != 0:
        raise PortableArchiveError("Portable archive encryption failed")


def create_portable_archive(
    transport: PortableTransport, budget_id: str, output_directory: Path
) -> Path:
    output_directory = output_directory.expanduser().resolve()
    output_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final = output_directory / f"budget-portable-{timestamp}.tar.gz.age"
    if final.exists():
        raise PortableArchiveError("A portable archive with this timestamp already exists")
    with tempfile.TemporaryDirectory(prefix=".budget-portable-", dir=output_directory) as temporary_name:
        temporary = Path(temporary_name)
        root = temporary / "payload"
        stage_portable_payload(transport, budget_id, root)
        tar_path = temporary / "portable.tar.gz"
        with tarfile.open(tar_path, "w:gz") as archive:
            archive.add(root / "manifest.json", arcname="manifest.json", recursive=False)
            archive.add(root / "data.json", arcname="data.json", recursive=False)
            archive.add(root / "attachments", arcname="attachments", recursive=True)
        encrypted = temporary / "complete.age"
        _encrypt(tar_path, encrypted)
        os.link(encrypted, final)
        os.chmod(final, 0o600)
    return final


def main(arguments: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--budget-id", required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args(arguments)
    try:
        transport = APITransport(args.server_url, os.environ.get("BUDGET_APP_ACCESS_TOKEN", ""))
        result = create_portable_archive(transport, args.budget_id, args.output_directory)
        print(f"Encrypted portable archive complete: {result}")
        return 0
    except (OSError, PortableArchiveError, tarfile.TarError) as failure:
        print(f"Portable archive error: {failure}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
