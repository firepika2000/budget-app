from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path

import pytest

from scripts.backup_destination import (
    DROPBOX_UPLOAD_CHUNK_SIZE,
    DestinationError,
    DropboxDestination,
    LocalDirectoryDestination,
    dropbox_content_hash,
    load_dropbox_credentials,
    sha256_file,
)


def test_dropbox_credentials_file_is_strict_private_and_declarative(tmp_path):
    credentials = tmp_path / "dropbox.env"
    credentials.write_text(
        "# owner-held Dropbox grant\n"
        "BUDGET_APP_DROPBOX_REFRESH_TOKEN=refresh=value\n"
        "BUDGET_APP_DROPBOX_APP_KEY=public-app-key\n"
    )
    credentials.chmod(0o600)
    assert load_dropbox_credentials(credentials) == {
        "BUDGET_APP_DROPBOX_REFRESH_TOKEN": "refresh=value",
        "BUDGET_APP_DROPBOX_APP_KEY": "public-app-key",
    }

    credentials.write_text("BUDGET_APP_DROPBOX_ACCESS_TOKEN=token\nUNSAFE_COMMAND=anything\n")
    with pytest.raises(DestinationError, match="Unsupported"):
        load_dropbox_credentials(credentials)
    credentials.write_text("BUDGET_APP_DROPBOX_ACCESS_TOKEN=one\nBUDGET_APP_DROPBOX_ACCESS_TOKEN=two\n")
    with pytest.raises(DestinationError, match="Duplicate"):
        load_dropbox_credentials(credentials)
    credentials.write_text("BUDGET_APP_DROPBOX_ACCESS_TOKEN=token\n")
    credentials.chmod(0o644)
    with pytest.raises(DestinationError, match="owner-only"):
        load_dropbox_credentials(credentials)
    credentials.chmod(0o600)
    credentials.write_text("BUDGET_APP_DROPBOX_ACCESS_TOKEN= token\n")
    with pytest.raises(DestinationError, match="Invalid Dropbox credential value"):
        load_dropbox_credentials(credentials)


def test_dropbox_credentials_reject_ambiguous_or_incomplete_authentication(tmp_path):
    credentials = tmp_path / "dropbox.env"
    credentials.write_text(
        "BUDGET_APP_DROPBOX_ACCESS_TOKEN=direct\n"
        "BUDGET_APP_DROPBOX_REFRESH_TOKEN=refresh\n"
        "BUDGET_APP_DROPBOX_APP_KEY=key\n"
    )
    credentials.chmod(0o600)
    with pytest.raises(DestinationError, match="either"):
        load_dropbox_credentials(credentials)
    credentials.write_text("BUDGET_APP_DROPBOX_REFRESH_TOKEN=refresh\n")
    with pytest.raises(DestinationError, match="refresh token plus app key"):
        load_dropbox_credentials(credentials)


def encrypted_backup(directory: Path, name: str = "budget-20260927T120000Z.tar.gz.age", size: int = 64) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    value = directory / name
    value.write_bytes((b"age-encryption.org/v1\n" + b"encrypted-budget-payload") * size)
    return value


def test_local_destination_atomically_publishes_verifies_and_retains_generations(tmp_path):
    source = encrypted_backup(tmp_path / "source")
    destination = tmp_path / "destination"
    result = LocalDirectoryDestination(destination, keep=2).publish(source)

    published = destination / source.name
    assert published.read_bytes() == source.read_bytes()
    assert result["sha256"] == sha256_file(source)
    assert json.loads((destination / "backup-status.json").read_text())["filename"] == source.name
    assert not list(destination.glob(".*.upload"))

    second = encrypted_backup(tmp_path / "second", "budget-20260928T120000Z.tar.gz.age")
    third = encrypted_backup(tmp_path / "third", "budget-20260929T120000Z.tar.gz.age")
    LocalDirectoryDestination(destination, keep=2).publish(second)
    final = LocalDirectoryDestination(destination, keep=2).publish(third)
    assert sorted(item.name for item in destination.glob("budget-*.tar.gz.age")) == [second.name, third.name]
    assert final["removed_generations"] == [source.name]
    listed = LocalDirectoryDestination(destination).list_generations()
    assert [item["name"] for item in listed] == [third.name, second.name]
    assert listed[0]["sha256"] == sha256_file(third)


def test_local_destination_refuses_plaintext_empty_and_overwrite(tmp_path):
    destination = LocalDirectoryDestination(tmp_path / "destination")
    plaintext = tmp_path / "backup.tar.gz"
    plaintext.write_bytes(b"private financial data")
    with pytest.raises(DestinationError, match="encrypted"):
        destination.publish(plaintext)
    empty = tmp_path / "budget-empty.tar.gz.age"
    empty.touch()
    with pytest.raises(DestinationError, match="empty"):
        destination.publish(empty)
    disguised_plaintext = tmp_path / "budget-plaintext.tar.gz.age"
    disguised_plaintext.write_bytes(b"private financial data")
    with pytest.raises(DestinationError, match="age encryption envelope"):
        destination.publish(disguised_plaintext)
    source = encrypted_backup(tmp_path / "source")
    destination.publish(source)
    with pytest.raises(DestinationError, match="already exists"):
        destination.publish(source)


class FakeDropbox:
    def __init__(self):
        self.calls: list[tuple[str, dict[str, object], bytes | None]] = []
        self.sessions: dict[str, bytearray] = {}
        self.files: dict[str, bytes] = {}
        self.modified: dict[str, str] = {}

    def rpc(self, endpoint: str, payload: dict[str, object]) -> dict[str, object]:
        self.calls.append((endpoint, payload, None))
        if endpoint == "files/create_folder_v2":
            return {"metadata": {"path_display": payload["path"]}}
        if endpoint == "files/get_metadata":
            body = self.files[str(payload["path"])]
            path = tmp_file_with(body)
            try:
                return {"size": len(body), "content_hash": dropbox_content_hash(path)}
            finally:
                path.unlink()
        if endpoint == "files/move_v2":
            source, destination = str(payload["from_path"]), str(payload["to_path"])
            if destination in self.files:
                raise DestinationError("path/conflict/file")
            self.files[destination] = self.files.pop(source)
            self.modified[destination] = "2026-09-27T12:00:00Z"
            return {"metadata": {"path_display": destination}}
        if endpoint == "files/list_folder":
            entries = [
                {"name": Path(path).name, "path_display": path, "path_lower": path.lower(),
                 "server_modified": self.modified.get(path, "2026-09-27T12:00:00Z"),
                 "size": len(body), "content_hash": hashlib.sha256(body).hexdigest(), ".tag": "file"}
                for path, body in self.files.items() if path.startswith(str(payload["path"]) + "/")
            ]
            return {"entries": entries, "has_more": False}
        if endpoint == "files/delete_v2":
            self.files.pop(str(payload["path"]), None)
            return {}
        raise AssertionError(endpoint)

    def content(self, endpoint: str, arguments: dict[str, object], body: bytes) -> dict[str, object]:
        self.calls.append((endpoint, arguments, body))
        if endpoint == "files/upload_session/start":
            self.sessions["session"] = bytearray(body)
            return {"session_id": "session"}
        cursor = arguments["cursor"]
        assert isinstance(cursor, dict)
        assert cursor["offset"] == len(self.sessions["session"])
        self.sessions["session"].extend(body)
        if endpoint == "files/upload_session/finish":
            commit = arguments["commit"]
            assert isinstance(commit, dict)
            self.files[str(commit["path"])] = bytes(self.sessions.pop("session"))
            return {"size": len(body)}
        assert endpoint == "files/upload_session/append_v2"
        return {}

    def download(self, remote_path: str, output: io.BufferedWriter) -> dict[str, object]:
        self.calls.append(("files/download", {"path": remote_path}, None))
        body = self.files[remote_path]
        output.write(body)
        path = tmp_file_with(body)
        try:
            return {"size": len(body), "content_hash": dropbox_content_hash(path)}
        finally:
            path.unlink()


_temporary_counter = 0


def tmp_file_with(body: bytes) -> Path:
    global _temporary_counter
    _temporary_counter += 1
    path = Path("/tmp") / f"budget-dropbox-hash-test-{_temporary_counter}"
    path.write_bytes(body)
    return path


def test_dropbox_destination_uses_bounded_session_verifies_then_promotes_and_downloads(tmp_path):
    source = encrypted_backup(tmp_path / "source", size=(DROPBOX_UPLOAD_CHUNK_SIZE // 48) + 1000)
    transport = FakeDropbox()
    destination = DropboxDestination(transport, keep=3)

    result = destination.publish(source)
    remote_path = f"/Backups/{source.name}"
    assert transport.files[remote_path] == source.read_bytes()
    assert result["content_hash"] == dropbox_content_hash(source)
    upload_calls = [call for call in transport.calls if call[0].startswith("files/upload_session")]
    assert len(upload_calls) >= 2
    assert all(len(call[2] or b"") <= DROPBOX_UPLOAD_CHUNK_SIZE for call in upload_calls)
    assert [call[0] for call in transport.calls].index("files/get_metadata") < [call[0] for call in transport.calls].index("files/move_v2")

    listed = destination.list_generations()
    assert [item["path"] for item in listed] == [remote_path]
    assert listed[0]["size"] == source.stat().st_size

    output = tmp_path / "retrieved" / source.name
    fetched = destination.fetch(remote_path, output)
    assert output.read_bytes() == source.read_bytes()
    assert fetched["sha256"] == hashlib.sha256(source.read_bytes()).hexdigest()


def test_dropbox_failed_verification_never_promotes_generation(tmp_path):
    source = encrypted_backup(tmp_path / "source")
    transport = FakeDropbox()
    original_rpc = transport.rpc

    def corrupt_metadata(endpoint: str, payload: dict[str, object]) -> dict[str, object]:
        response = original_rpc(endpoint, payload)
        if endpoint == "files/get_metadata":
            response["content_hash"] = "0" * 64
        return response

    transport.rpc = corrupt_metadata  # type: ignore[method-assign]
    with pytest.raises(DestinationError, match="verification failed"):
        DropboxDestination(transport).publish(source)
    assert not any(call[0] == "files/move_v2" for call in transport.calls)
    assert not transport.files
