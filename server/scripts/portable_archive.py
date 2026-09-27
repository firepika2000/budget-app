#!/usr/bin/env python3
"""Create an encrypted, provider-neutral Budget data archive through the production API."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
from typing import Protocol
from urllib import error, parse, request

from app.portable_data import FORMAT_NAME, FORMAT_VERSION, canonical_json, validate_section_manifest


MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 25_000
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


def _decrypt(source: Path, destination: Path) -> None:
    executable = shutil.which("age")
    if not executable:
        raise PortableArchiveError("age is required for encrypted portable archives")
    command = [executable, "--decrypt"]
    identity = os.environ.get("BUDGET_APP_BACKUP_AGE_IDENTITY", "").strip()
    if identity:
        identity_path = Path(identity).expanduser().resolve()
        if not identity_path.is_file():
            raise PortableArchiveError("Configured age identity file was not found")
        command += ["--identity", str(identity_path)]
    command += ["--output", str(destination), str(source)]
    if subprocess.run(command).returncode != 0:
        raise PortableArchiveError("Portable archive decryption failed")


def _valid_archive_name(name: str, directory: bool) -> str:
    normalized = name.rstrip("/") if directory else name
    path = PurePosixPath(normalized)
    if (not normalized or path.is_absolute() or ".." in path.parts or normalized != str(path)
            or "\\" in normalized or any(ord(character) < 32 for character in normalized)):
        raise PortableArchiveError("Portable archive contains an unsafe member name")
    if directory:
        allowed = normalized == "attachments"
    else:
        allowed = normalized in {"data.json", "manifest.json"} or (
            len(path.parts) == 2 and path.parts[0] == "attachments" and _safe_id(path.parts[1]) == path.parts[1]
        )
    if not allowed:
        raise PortableArchiveError("Portable archive contains an unexpected member")
    return normalized


def extract_and_validate_archive(archive: Path, destination: Path) -> dict:
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    with tarfile.open(archive, "r:gz") as source:
        members: dict[str, tarfile.TarInfo] = {}
        for member in source:
            if member.size < 0 or not (member.isfile() or member.isdir()):
                raise PortableArchiveError("Portable archive contains an unsafe member type")
            name = _valid_archive_name(member.name, member.isdir())
            if name in members:
                raise PortableArchiveError("Portable archive contains a duplicate member")
            members[name] = member
            if len(members) > MAX_ARCHIVE_MEMBERS:
                raise PortableArchiveError("Portable archive contains too many members")
        if not {"manifest.json", "data.json", "attachments"} <= set(members):
            raise PortableArchiveError("Portable archive is incomplete")
        for name, member in members.items():
            path = destination / name
            if member.isdir():
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, path.open("xb") as output:
                remaining_limit = 256 * 1024 * 1024 if name in {"data.json", "manifest.json"} else MAX_ATTACHMENT_BYTES
                copied = 0
                for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
                    copied += len(chunk)
                    if copied > remaining_limit:
                        raise PortableArchiveError("Portable archive member exceeds its supported size")
                    output.write(chunk)
            os.chmod(path, 0o600)

    try:
        manifest = json.loads((destination / "manifest.json").read_text())
        payload = json.loads((destination / "data.json").read_text())
    except (UnicodeDecodeError, json.JSONDecodeError) as failure:
        raise PortableArchiveError("Portable archive metadata is invalid") from failure
    if manifest.get("format") != "budget-app-portable-archive" or manifest.get("format_version") != 1:
        raise PortableArchiveError("Portable archive version is unsupported")
    data_bytes = (destination / "data.json").read_bytes()
    if hashlib.sha256(data_bytes).hexdigest() != manifest.get("data_sha256"):
        raise PortableArchiveError("Portable archive data failed integrity validation")
    if payload.get("format") != FORMAT_NAME or payload.get("schema_version") != FORMAT_VERSION:
        raise PortableArchiveError("Portable data version is unsupported")
    sections = {key: value for key, value in payload.items() if key not in METADATA_KEYS}
    try:
        validate_section_manifest(sections, payload.get("section_manifest", {}))
    except ValueError as failure:
        raise PortableArchiveError(str(failure)) from failure
    expected: dict[str, dict] = {}
    for item in sections.get("transaction_attachments", []):
        if isinstance(item, dict) and item.get("detached_at") is None:
            expected[_safe_id(item.get("id"))] = item
    attachment_manifest = manifest.get("attachments")
    if not isinstance(attachment_manifest, dict) or set(attachment_manifest) != set(expected):
        raise PortableArchiveError("Portable archive attachment manifest is incomplete")
    actual_files = {item.name for item in (destination / "attachments").iterdir() if item.is_file()}
    if actual_files != set(expected):
        raise PortableArchiveError("Portable archive attachment payload coverage is incomplete")
    for attachment_id, item in expected.items():
        path = destination / "attachments" / attachment_id
        entry = attachment_manifest[attachment_id]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if (path.stat().st_size != item.get("byte_count") or digest != item.get("sha256")
                or entry.get("byte_count") != item.get("byte_count") or entry.get("sha256") != digest):
            raise PortableArchiveError(f"Portable attachment failed integrity validation: {attachment_id}")
    return payload


def validate_portable_archive(encrypted: Path) -> dict[str, object]:
    encrypted = encrypted.expanduser().resolve()
    if not encrypted.is_file() or encrypted.is_symlink():
        raise PortableArchiveError("Encrypted portable archive was not found")
    with tempfile.TemporaryDirectory(prefix=".budget-portable-verify-", dir=encrypted.parent) as name:
        temporary = Path(name)
        archive = temporary / "portable.tar.gz"
        _decrypt(encrypted, archive)
        payload = extract_and_validate_archive(archive, temporary / "verified")
        return {
            "budget_id": payload["budget"]["id"],
            "transactions": len(payload.get("transactions", [])),
            "attachments": len([
                item for item in payload.get("transaction_attachments", [])
                if item.get("detached_at") is None
            ]),
        }


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
    subparsers = parser.add_subparsers(dest="operation", required=True)
    export = subparsers.add_parser("export", help="create an encrypted archive")
    export.add_argument("--server-url", required=True)
    export.add_argument("--budget-id", required=True)
    export.add_argument("--output-directory", type=Path, required=True)
    verify = subparsers.add_parser("verify", help="decrypt and validate without importing")
    verify.add_argument("archive", type=Path)
    args = parser.parse_args(arguments)
    try:
        if args.operation == "verify":
            result = validate_portable_archive(args.archive)
            print(
                "Portable archive verified: "
                f"budget={result['budget_id']} transactions={result['transactions']} "
                f"attachments={result['attachments']}"
            )
        else:
            transport = APITransport(args.server_url, os.environ.get("BUDGET_APP_ACCESS_TOKEN", ""))
            result = create_portable_archive(transport, args.budget_id, args.output_directory)
            print(f"Encrypted portable archive complete: {result}")
        return 0
    except (OSError, PortableArchiveError, tarfile.TarError) as failure:
        print(f"Portable archive error: {failure}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
