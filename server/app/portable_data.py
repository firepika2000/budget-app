"""Provider-neutral integrity envelope for portable budget data.

This module intentionally knows nothing about PostgreSQL, SQLite, or attachment storage.  The same
canonical JSON/hash rules can therefore be used by the server exporter and a future on-device
importer.  Import remains validate-then-commit work; this module does not mutate an authority.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from fastapi.encoders import jsonable_encoder


FORMAT_NAME = "budget-app-portable-data"
FORMAT_VERSION = 2


def canonical_json(value: Any) -> bytes:
    encoded = jsonable_encoder(value)
    return json.dumps(
        encoded,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def section_manifest(sections: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for name, value in sorted(sections.items()):
        if isinstance(value, list):
            record_count = len(value)
        elif value is None:
            record_count = 0
        else:
            record_count = 1
        result[name] = {
            "record_count": record_count,
            "sha256": hashlib.sha256(canonical_json(value)).hexdigest(),
        }
    return result


def validate_section_manifest(
    sections: dict[str, Any], manifest: dict[str, dict[str, Any]]
) -> None:
    expected = section_manifest(sections)
    if set(manifest) != set(expected):
        raise ValueError("Portable data section manifest does not match the payload")
    for name, expected_entry in expected.items():
        actual_entry = manifest[name]
        if actual_entry != expected_entry:
            raise ValueError(f"Portable data section failed integrity validation: {name}")
