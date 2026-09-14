from __future__ import annotations

import unicodedata


def display_payee_name(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).strip().split())


def normalized_payee_name(value: str) -> str:
    return display_payee_name(value).casefold()
