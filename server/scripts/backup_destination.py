#!/usr/bin/env python3
"""Publish and retrieve encrypted Budget backup generations.

Dropbox is deliberately a backup destination, never a live database.  This tool only accepts
already-encrypted ``.age`` artifacts produced by the coordinated backup workflow.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time
from typing import BinaryIO, Protocol
from urllib import error, parse, request
import uuid


DROPBOX_CONTENT_BLOCK_SIZE = 4 * 1024 * 1024
DROPBOX_UPLOAD_CHUNK_SIZE = 8 * 1024 * 1024


class DestinationError(RuntimeError):
    pass


def _require_encrypted_backup(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file() or path.is_symlink():
        raise DestinationError(f"Encrypted backup not found: {path}")
    if not path.name.endswith(".tar.gz.age"):
        raise DestinationError("Only encrypted .tar.gz.age Budget backups can be published")
    if path.stat().st_size == 0:
        raise DestinationError("Encrypted backup is empty")
    with path.open("rb") as stream:
        if stream.read(len(b"age-encryption.org/v1\n")) != b"age-encryption.org/v1\n":
            raise DestinationError("Backup does not contain an authenticated age encryption envelope")
    return path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dropbox_content_hash(path: Path) -> str:
    overall = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(DROPBOX_CONTENT_BLOCK_SIZE), b""):
            overall.update(hashlib.sha256(block).digest())
    return overall.hexdigest()


def _write_status(directory: Path, payload: dict[str, object]) -> None:
    status = directory / "backup-status.json"
    temporary = directory / f".{status.name}.{uuid.uuid4().hex}.tmp"
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, status)


class LocalDirectoryDestination:
    def __init__(self, directory: Path, keep: int = 10):
        if keep < 1:
            raise DestinationError("Retention must keep at least one backup")
        self.directory = directory.expanduser().resolve()
        self.keep = keep

    def publish(self, source: Path) -> dict[str, object]:
        source = _require_encrypted_backup(source)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination = self.directory / source.name
        if destination.exists():
            raise DestinationError(f"Backup generation already exists: {destination}")
        staging = self.directory / f".{source.name}.{uuid.uuid4().hex}.upload"
        try:
            with source.open("rb") as incoming, staging.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
                outgoing.flush()
                os.fsync(outgoing.fileno())
            os.chmod(staging, 0o600)
            expected = sha256_file(source)
            if sha256_file(staging) != expected:
                raise DestinationError("Local backup verification failed before publication")
            os.replace(staging, destination)
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            removed = self._apply_retention()
            result: dict[str, object] = {
                "destination": "local",
                "path": str(destination),
                "filename": destination.name,
                "size": destination.stat().st_size,
                "sha256": expected,
                "verified_at": int(time.time()),
                "removed_generations": removed,
            }
            _write_status(self.directory, result)
            return result
        finally:
            staging.unlink(missing_ok=True)

    def _apply_retention(self) -> list[str]:
        generations = sorted(
            (item for item in self.directory.glob("budget-*.tar.gz.age") if item.is_file() and not item.is_symlink()),
            key=lambda item: (item.stat().st_mtime_ns, item.name),
            reverse=True,
        )
        removed: list[str] = []
        for expired in generations[self.keep :]:
            expired.unlink()
            removed.append(expired.name)
        return removed


class DropboxTransport(Protocol):
    def rpc(self, endpoint: str, payload: dict[str, object]) -> dict[str, object]: ...
    def content(self, endpoint: str, arguments: dict[str, object], body: bytes) -> dict[str, object]: ...
    def download(self, remote_path: str, output: BinaryIO) -> dict[str, object]: ...


class DropboxHTTPTransport:
    def __init__(self, access_token: str, timeout: float = 60):
        if not access_token.strip():
            raise DestinationError("Dropbox access token is missing")
        self.access_token = access_token
        self.timeout = timeout

    def _open(self, value: request.Request):
        try:
            return request.urlopen(value, timeout=self.timeout)
        except error.HTTPError as failure:
            detail = failure.read(4096).decode("utf-8", errors="replace")
            raise DestinationError(f"Dropbox request failed ({failure.code}): {detail}") from failure
        except error.URLError as failure:
            raise DestinationError(f"Dropbox connection failed: {failure.reason}") from failure

    def rpc(self, endpoint: str, payload: dict[str, object]) -> dict[str, object]:
        value = request.Request(
            f"https://api.dropboxapi.com/2/{endpoint}",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={"Authorization": f"Bearer {self.access_token}", "Content-Type": "application/json"},
        )
        with self._open(value) as response:
            return json.loads(response.read())

    def content(self, endpoint: str, arguments: dict[str, object], body: bytes) -> dict[str, object]:
        value = request.Request(
            f"https://content.dropboxapi.com/2/{endpoint}",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Content-Type": "application/octet-stream",
                "Dropbox-API-Arg": json.dumps(arguments, separators=(",", ":")),
            },
        )
        with self._open(value) as response:
            payload = response.read()
            return json.loads(payload) if payload else {}

    def download(self, remote_path: str, output: BinaryIO) -> dict[str, object]:
        value = request.Request(
            "https://content.dropboxapi.com/2/files/download",
            data=b"",
            method="POST",
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Dropbox-API-Arg": json.dumps({"path": remote_path}, separators=(",", ":")),
            },
        )
        with self._open(value) as response:
            metadata = json.loads(response.headers["Dropbox-API-Result"])
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
            return metadata


def dropbox_access_token(environment: dict[str, str] | None = None) -> str:
    environment = os.environ if environment is None else environment
    direct = environment.get("BUDGET_APP_DROPBOX_ACCESS_TOKEN", "").strip()
    if direct:
        return direct
    refresh = environment.get("BUDGET_APP_DROPBOX_REFRESH_TOKEN", "").strip()
    app_key = environment.get("BUDGET_APP_DROPBOX_APP_KEY", "").strip()
    app_secret = environment.get("BUDGET_APP_DROPBOX_APP_SECRET", "").strip()
    if not (refresh and app_key):
        raise DestinationError(
            "Configure BUDGET_APP_DROPBOX_ACCESS_TOKEN or the Dropbox refresh-token/app-key credentials"
        )
    fields = {"grant_type": "refresh_token", "refresh_token": refresh}
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if app_secret:
        credentials = base64.b64encode(f"{app_key}:{app_secret}".encode()).decode()
        headers["Authorization"] = f"Basic {credentials}"
    else:
        fields["client_id"] = app_key
    payload = parse.urlencode(fields).encode()
    token_request = request.Request(
        "https://api.dropboxapi.com/oauth2/token",
        data=payload,
        method="POST",
        headers=headers,
    )
    try:
        with request.urlopen(token_request, timeout=30) as response:
            return str(json.loads(response.read())["access_token"])
    except (error.URLError, error.HTTPError, KeyError, ValueError) as failure:
        raise DestinationError("Unable to refresh Dropbox credentials") from failure


class DropboxDestination:
    def __init__(self, transport: DropboxTransport, folder: str = "/Backups", keep: int = 10):
        if keep < 1:
            raise DestinationError("Retention must keep at least one backup")
        folder = "/" + folder.strip("/")
        if folder == "/":
            raise DestinationError("Dropbox backup folder must not be the account root")
        self.transport = transport
        self.folder = folder
        self.keep = keep

    def publish(self, source: Path) -> dict[str, object]:
        source = _require_encrypted_backup(source)
        self._ensure_folder()
        temporary_path = f"{self.folder}/.upload-{uuid.uuid4().hex}"
        final_path = f"{self.folder}/{source.name}"
        session_id: str | None = None
        try:
            with source.open("rb") as stream:
                first = stream.read(DROPBOX_UPLOAD_CHUNK_SIZE)
                started = self.transport.content("files/upload_session/start", {"close": False}, first)
                session_id = str(started["session_id"])
                offset = len(first)
                while True:
                    chunk = stream.read(DROPBOX_UPLOAD_CHUNK_SIZE)
                    if not chunk:
                        break
                    following = stream.read(DROPBOX_UPLOAD_CHUNK_SIZE)
                    cursor = {"session_id": session_id, "offset": offset}
                    if following:
                        self.transport.content("files/upload_session/append_v2", {"cursor": cursor, "close": False}, chunk)
                        offset += len(chunk)
                        stream.seek(-len(following), os.SEEK_CUR)
                    else:
                        commit = {"path": temporary_path, "mode": "add", "autorename": False, "mute": True}
                        self.transport.content("files/upload_session/finish", {"cursor": cursor, "commit": commit}, chunk)
                        offset += len(chunk)
                        break
                if offset == 0:
                    raise DestinationError("Encrypted backup is empty")
                if offset == len(first):
                    cursor = {"session_id": session_id, "offset": offset}
                    commit = {"path": temporary_path, "mode": "add", "autorename": False, "mute": True}
                    self.transport.content("files/upload_session/finish", {"cursor": cursor, "commit": commit}, b"")
            metadata = self.transport.rpc("files/get_metadata", {"path": temporary_path})
            expected_hash = dropbox_content_hash(source)
            if int(metadata.get("size", -1)) != source.stat().st_size or metadata.get("content_hash") != expected_hash:
                raise DestinationError("Dropbox upload verification failed before publication")
            self.transport.rpc("files/move_v2", {"from_path": temporary_path, "to_path": final_path, "autorename": False})
            temporary_path = ""
            removed = self._apply_retention()
            return {
                "destination": "dropbox",
                "path": final_path,
                "filename": source.name,
                "size": source.stat().st_size,
                "content_hash": expected_hash,
                "sha256": sha256_file(source),
                "verified_at": int(time.time()),
                "removed_generations": removed,
            }
        finally:
            if temporary_path:
                try:
                    self.transport.rpc("files/delete_v2", {"path": temporary_path})
                except DestinationError:
                    pass

    def _ensure_folder(self) -> None:
        current = ""
        for component in self.folder.strip("/").split("/"):
            current += "/" + component
            try:
                self.transport.rpc("files/create_folder_v2", {"path": current, "autorename": False})
            except DestinationError as failure:
                if "conflict" not in str(failure).lower():
                    raise

    def _apply_retention(self) -> list[str]:
        response = self.transport.rpc("files/list_folder", {"path": self.folder, "recursive": False, "limit": 100})
        entries = list(response.get("entries", []))
        while response.get("has_more"):
            response = self.transport.rpc("files/list_folder/continue", {"cursor": response["cursor"]})
            entries.extend(response.get("entries", []))
        generations = sorted(
            (entry for entry in entries if str(entry.get("name", "")).startswith("budget-") and str(entry.get("name", "")).endswith(".tar.gz.age")),
            key=lambda entry: (str(entry.get("server_modified", "")), str(entry.get("name", ""))),
            reverse=True,
        )
        removed: list[str] = []
        for expired in generations[self.keep :]:
            path = str(expired.get("path_lower") or expired.get("path_display"))
            self.transport.rpc("files/delete_v2", {"path": path})
            removed.append(str(expired["name"]))
        return removed

    def fetch(self, remote_path: str, output: Path) -> dict[str, object]:
        if not remote_path.startswith(self.folder + "/") or not remote_path.endswith(".tar.gz.age"):
            raise DestinationError("Remote backup path is outside the configured encrypted backup folder")
        output = output.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            raise DestinationError(f"Restore download already exists: {output}")
        temporary = output.parent / f".{output.name}.{uuid.uuid4().hex}.download"
        try:
            with temporary.open("xb") as stream:
                metadata = self.transport.download(remote_path, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, 0o600)
            if int(metadata.get("size", -1)) != temporary.stat().st_size:
                raise DestinationError("Dropbox download size verification failed")
            if metadata.get("content_hash") != dropbox_content_hash(temporary):
                raise DestinationError("Dropbox download integrity verification failed")
            os.replace(temporary, output)
            return {"destination": "dropbox", "path": str(output), "remote_path": remote_path,
                    "size": output.stat().st_size, "sha256": sha256_file(output)}
        finally:
            temporary.unlink(missing_ok=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Publish or retrieve encrypted Budget backups")
    subparsers = parser.add_subparsers(dest="command", required=True)
    publish = subparsers.add_parser("publish")
    publish.add_argument("backup", type=Path)
    publish.add_argument("--destination", choices=("local", "dropbox"), required=True)
    publish.add_argument("--directory", type=Path)
    publish.add_argument("--dropbox-folder", default="/Backups")
    publish.add_argument("--keep", type=int, default=10)
    fetch = subparsers.add_parser("fetch-dropbox")
    fetch.add_argument("remote_path")
    fetch.add_argument("output", type=Path)
    fetch.add_argument("--dropbox-folder", default="/Backups")
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = _parser().parse_args(arguments)
    try:
        if args.command == "publish" and args.destination == "local":
            if args.directory is None:
                raise DestinationError("--directory is required for a local destination")
            result = LocalDirectoryDestination(args.directory, args.keep).publish(args.backup)
        else:
            transport = DropboxHTTPTransport(dropbox_access_token())
            destination = DropboxDestination(transport, args.dropbox_folder, getattr(args, "keep", 10))
            result = destination.publish(args.backup) if args.command == "publish" else destination.fetch(args.remote_path, args.output)
        print(json.dumps(result, sort_keys=True))
        return 0
    except DestinationError as failure:
        print(f"Backup destination error: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
