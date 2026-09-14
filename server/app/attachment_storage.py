from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
SUPPORTED_TYPES = {"application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"}


def safe_filename(value: str) -> str:
    value = Path(value.replace("\\", "/")).name.strip()
    cleaned = "".join(character for character in value if character.isprintable() and character not in {"/", "\\", "\0"})
    return (cleaned or "attachment")[:255]


def validate_content(content: bytes, content_type: str) -> None:
    if not content or len(content) > MAX_ATTACHMENT_BYTES:
        raise ValueError("Attachment must contain 1 byte through 10 MB")
    signatures = {
        "application/pdf": content.startswith(b"%PDF-"),
        "image/jpeg": content.startswith(b"\xff\xd8\xff"),
        "image/png": content.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/heic": len(content) >= 12 and content[4:8] == b"ftyp" and content[8:12] in {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"},
        "image/heif": len(content) >= 12 and content[4:8] == b"ftyp" and content[8:12] in {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"},
    }
    if content_type not in SUPPORTED_TYPES or not signatures.get(content_type, False):
        raise ValueError("Only valid PDF, JPEG, PNG, and HEIC attachments are supported")


class AttachmentStorage:
    def __init__(self, root: str, deployment_secret: str, configured_key: Optional[str] = None):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if configured_key:
            try:
                key = base64.urlsafe_b64decode(configured_key)
            except Exception as exc:
                raise ValueError("BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY must be URL-safe base64") from exc
            if len(key) != 32:
                raise ValueError("BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY must decode to 32 bytes")
        else:
            key = hashlib.sha256((deployment_secret + ":budget-attachments:v1").encode()).digest()
        self.cipher = AESGCM(key)

    def write(self, storage_key: str, content: bytes) -> None:
        nonce = os.urandom(12)
        target = self.root / storage_key
        temporary = self.root / f".{storage_key}.tmp"
        temporary.write_bytes(nonce + self.cipher.encrypt(nonce, content, storage_key.encode()))
        os.chmod(temporary, 0o600)
        temporary.replace(target)

    def read(self, storage_key: str) -> bytes:
        payload = (self.root / storage_key).read_bytes()
        return self.cipher.decrypt(payload[:12], payload[12:], storage_key.encode())

    def delete(self, storage_key: str) -> None:
        try:
            (self.root / storage_key).unlink()
        except FileNotFoundError:
            pass
