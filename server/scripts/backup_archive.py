#!/usr/bin/env python3
"""Validate complete backup payloads in private staging, never a live destination."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile

REQUIRED = {"BACKUP-METADATA", "database.sql", "attachment-key-recovery.env", "MANIFEST.sha256"}
MAX_MEMBERS = 250_000
MAX_MANIFEST_BYTES = 64 * 1024 * 1024


def valid_name(name: str, *, directory: bool) -> str:
    normalized = name.rstrip("/") if directory else name
    path = PurePosixPath(normalized)
    if (not normalized or path.is_absolute() or ".." in path.parts
            or normalized != str(path) or "\\" in normalized
            or any(ord(character) < 32 or ord(character) == 127 for character in normalized)):
        raise ValueError("Unsafe backup member name")
    if directory:
        allowed = normalized == "attachments" or normalized.startswith("attachments/")
    else:
        allowed = normalized in REQUIRED or normalized.startswith("attachments/")
    if not allowed:
        raise ValueError("Unexpected backup member")
    return normalized


def digest(stream) -> str:
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()


def create_manifest(root: Path) -> None:
    files: dict[str, Path] = {}
    for directory, directories, names in os.walk(root, followlinks=False):
        for name in directories + names:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise ValueError("Backup payload must contain only regular files and directories")
            relative = valid_name(path.relative_to(root).as_posix(), directory=stat.S_ISDIR(mode))
            if stat.S_ISREG(mode) and relative != "MANIFEST.sha256":
                files[relative] = path
    if not (REQUIRED - {"MANIFEST.sha256"}) <= files.keys() or not (root / "attachments").is_dir():
        raise ValueError("Backup is incomplete")
    if len(files) > MAX_MEMBERS:
        raise ValueError("Backup contains too many files")
    lines = []
    for name, path in sorted(files.items()):
        with path.open("rb") as stream:
            lines.append(f"{digest(stream)}  {name}\n")
    (root / "MANIFEST.sha256").write_text("".join(lines), encoding="utf-8")


def extract_verified(archive: Path, destination: Path) -> None:
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError("Backup staging destination must be empty")
    with tarfile.open(archive, "r:gz") as source:
        members: dict[str, tarfile.TarInfo] = {}
        total_size = 0
        for member in source:
            if member.size < 0:
                raise ValueError("Invalid backup member size")
            if not (member.isfile() or member.isdir()):
                raise ValueError("Unsafe backup member type: links and special files are forbidden")
            name = valid_name(member.name, directory=member.isdir())
            if name in members:
                raise ValueError("Duplicate backup member")
            members[name] = member
            total_size += member.size
            if len(members) > MAX_MEMBERS:
                raise ValueError("Backup contains too many members")
        files = {name for name, member in members.items() if member.isfile()}
        if not REQUIRED <= files or "attachments" not in members or not members["attachments"].isdir():
            raise ValueError("Backup is incomplete")
        for name in members:
            if any(str(parent) in files for parent in PurePosixPath(name).parents):
                raise ValueError("Backup file/directory collision")
        if total_size > shutil.disk_usage(destination).free:
            raise ValueError("Insufficient free space for backup staging")
        if members["MANIFEST.sha256"].size > MAX_MANIFEST_BYTES or members["BACKUP-METADATA"].size > 65536:
            raise ValueError("Backup metadata exceeds supported bounds")
        with source.extractfile(members["MANIFEST.sha256"]) as stream:
            manifest = stream.read().decode("utf-8")
        expected: dict[str, str] = {}
        for line in manifest.splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match:
                raise ValueError("Invalid backup checksum manifest")
            checksum, name = match.groups()
            valid_name(name, directory=False)
            if name in expected:
                raise ValueError("Duplicate backup checksum entry")
            expected[name] = checksum
        if set(expected) != files - {"MANIFEST.sha256"}:
            raise ValueError("Backup checksum manifest does not cover every payload file exactly once")
        # Manual extraction never follows archive links, honors archive permissions or overwrites
        # an existing path. Only private staging is written; callers touch their target afterward.
        for name, member in members.items():
            path = destination / name
            if member.isdir():
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.extractfile(member) as stream, path.open("xb") as output:
                value = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    value.update(chunk)
                    output.write(chunk)
            if name != "MANIFEST.sha256" and value.hexdigest() != expected[name]:
                raise ValueError("Backup checksum verification failed")
        metadata = (destination / "BACKUP-METADATA").read_text(encoding="utf-8").splitlines()
        versions = [line for line in metadata if line.startswith("format_version=")]
        if versions != ["format_version=1"]:
            raise ValueError("Unsupported backup format version")


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["create-manifest", "extract-verified"])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        if args.operation == "create-manifest":
            create_manifest(args.source)
        elif args.destination is not None:
            extract_verified(args.source, args.destination)
        else:
            parser.error("extract-verified requires an empty staging destination")
    except (OSError, ValueError, tarfile.TarError) as error:
        # Never print archive payload, SQL, key recovery material or the passphrase.
        parser.exit(1, f"Backup validation failed: {error}\n")


if __name__ == "__main__":
    main()
