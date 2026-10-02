"""Bounded bank-statement adapters that produce money-neutral candidates.

Adapters parse untrusted files only. They never resolve payees, match transactions,
change clearing state, reconcile an account, or write to the ledger.
"""

from __future__ import annotations

import re
from datetime import date
from io import BytesIO

from pypdf import PdfReader

from .import_candidates import (
    MAX_FIELD_CHARS,
    MAX_FILE_BYTES,
    MAX_ROWS,
    ImportCandidate,
    ImportValidationError,
    parse_minor_units,
)


_OFX_TRANSACTION = re.compile(r"<STMTTRN\b[^>]*>(.*?)(?:</STMTTRN\s*>|(?=<STMTTRN\b)|(?=</BANKTRANLIST))", re.I | re.S)


def _bounded_text(data: bytes, format_name: str) -> str:
    if len(data) > MAX_FILE_BYTES:
        raise ImportValidationError("File exceeds 10 MB")
    if b"\x00" in data:
        raise ImportValidationError(f"{format_name} contains an unsupported control character")
    # OFX 1.x and QIF exports are often Windows-1252. Decode UTF-8 first so modern
    # exports retain their exact text; the single-byte fallback is deterministic.
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1252")
    if len(text) > MAX_FILE_BYTES:
        raise ImportValidationError("Decoded statement exceeds supported size")
    return text


def _clean_description(value: str, *, maximum: int, position: int) -> str:
    value = " ".join(value.replace("\r", " ").replace("\n", " ").split())
    if len(value) > maximum:
        raise ImportValidationError(f"Statement description exceeds supported length at record {position}")
    return value


def _ofx_value(block: str, tag: str) -> str | None:
    # Accept both XML-style OFX 2 and line-terminated SGML OFX 1. Values end at a
    # closing tag, the next tag, or a line ending. Markup is never interpreted.
    match = re.search(rf"<{tag}\b[^>]*>\s*([^<\r\n]*?)(?:\s*</{tag}\s*>|\r?\n|(?=<)|$)", block, re.I)
    return match.group(1).strip() if match else None


def parse_ofx_candidates(data: bytes, *, scale: int) -> list[ImportCandidate]:
    """Parse OFX or QFX bank transaction records without XML entity expansion."""
    parse_minor_units("0", scale=scale)
    text = _bounded_text(data, "OFX/QFX")
    if re.search(r"<!\s*(?:DOCTYPE|ENTITY)", text, re.I):
        raise ImportValidationError("OFX/QFX declarations are not supported")
    blocks = list(_OFX_TRANSACTION.finditer(text))
    if not blocks:
        raise ImportValidationError("OFX/QFX contains no bank transactions")
    if len(blocks) > MAX_ROWS:
        raise ImportValidationError("OFX/QFX exceeds 10000 transactions")

    candidates: list[ImportCandidate] = []
    for position, match in enumerate(blocks, start=1):
        block = match.group(1)
        raw_date = _ofx_value(block, "DTPOSTED")
        raw_amount = _ofx_value(block, "TRNAMT")
        if raw_date is None or raw_amount is None:
            raise ImportValidationError(f"Missing date or amount at record {position}")
        try:
            compact_date = raw_date.strip()[:8]
            if not re.fullmatch(r"[0-9]{8}", compact_date):
                raise ValueError()
            occurred_on = date(int(compact_date[:4]), int(compact_date[4:6]), int(compact_date[6:8]))
            amount_minor = parse_minor_units(raw_amount, scale=scale)
        except (ValueError, ImportValidationError):
            raise ImportValidationError(f"Invalid date or amount at record {position}") from None
        payee = _ofx_value(block, "NAME") or _ofx_value(block, "PAYEE") or ""
        memo = _ofx_value(block, "MEMO") or ""
        candidates.append(ImportCandidate(
            source_row=position,
            occurred_on=occurred_on,
            amount_minor=amount_minor,
            payee=_clean_description(payee, maximum=150, position=position),
            memo=_clean_description(memo, maximum=500, position=position),
        ))
    return candidates


def _qif_amount(value: str, *, scale: int) -> int:
    value = value.strip()
    if not re.fullmatch(r"[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?", value):
        raise ImportValidationError("Amount must be a plain decimal number")
    return parse_minor_units(value.replace(",", ""), scale=scale)


def parse_qif_candidates(data: bytes, *, scale: int, date_order: str) -> list[ImportCandidate]:
    """Parse QIF transactions with an explicit date order; never guess locale."""
    parse_minor_units("0", scale=scale)
    if date_order not in {"mdy", "dmy"}:
        raise ImportValidationError("QIF requires an explicit m/d/y or d/m/y date order")
    text = _bounded_text(data, "QIF")
    records = text.split("^")
    candidates: list[ImportCandidate] = []
    for raw_record in records:
        lines = [line.rstrip("\r") for line in raw_record.splitlines() if line and not line.startswith("!")]
        if not lines:
            continue
        position = len(candidates) + 1
        if position > MAX_ROWS:
            raise ImportValidationError("QIF exceeds 10000 transactions")
        fields: dict[str, str] = {}
        for line in lines:
            if len(line) > MAX_FIELD_CHARS:
                raise ImportValidationError(f"QIF field exceeds supported length at record {position}")
            code, value = line[0], line[1:]
            if code in {"D", "T", "P", "M"} and code not in fields:
                fields[code] = value
        if "D" not in fields or "T" not in fields:
            raise ImportValidationError(f"Missing date or amount at record {position}")
        try:
            date_match = re.fullmatch(r"\s*([0-9]{1,2})/([0-9]{1,2})/(?:'([0-9]{2})|([0-9]{4}))\s*", fields["D"])
            if date_match is None:
                raise ValueError()
            first, second = int(date_match.group(1)), int(date_match.group(2))
            year = int(date_match.group(4) or date_match.group(3))
            if year < 100:
                year += 2000 if year < 70 else 1900
            month, day = (first, second) if date_order == "mdy" else (second, first)
            occurred_on = date(year, month, day)
            amount_minor = _qif_amount(fields["T"], scale=scale)
        except (ValueError, ImportValidationError):
            raise ImportValidationError(f"Invalid date or amount at record {position}") from None
        candidates.append(ImportCandidate(
            source_row=position,
            occurred_on=occurred_on,
            amount_minor=amount_minor,
            payee=_clean_description(fields.get("P", ""), maximum=150, position=position),
            memo=_clean_description(fields.get("M", ""), maximum=500, position=position),
        ))
    if not candidates:
        raise ImportValidationError("QIF contains no transactions")
    return candidates


def _extract_pdf_text(data: bytes) -> list[str]:
    if len(data) > MAX_FILE_BYTES:
        raise ImportValidationError("File exceeds 10 MB")
    if not data.startswith(b"%PDF-"):
        raise ImportValidationError("File is not a valid PDF statement")
    try:
        reader = PdfReader(BytesIO(data), strict=True)
        if reader.is_encrypted or not 1 <= len(reader.pages) <= 200:
            raise ImportValidationError("PDF must be unencrypted and contain 1 to 200 pages")
        lines: list[str] = []
        character_count = 0
        for page in reader.pages:
            text = page.extract_text() or ""
            character_count += len(text)
            if character_count > MAX_FILE_BYTES:
                raise ImportValidationError("Extracted PDF text exceeds supported size")
            lines.extend(text.splitlines())
        return lines
    except ImportValidationError:
        raise
    except Exception:
        raise ImportValidationError("PDF text could not be read safely") from None


def parse_pdf_candidates(data: bytes, *, scale: int, date_order: str) -> list[ImportCandidate]:
    """Extract only unambiguous signed rows from a text-based statement PDF.

    PDF layout is not a financial contract. A row must begin with an explicit
    calendar date and end with a signed amount (`+12.34`, `-12.34`) or a
    parenthesized outflow (`(12.34)`). Everything between becomes review-only
    descriptive text. Unsigned values, balances, headers, and totals are ignored.
    """
    parse_minor_units("0", scale=scale)
    if date_order not in {"mdy", "dmy"}:
        raise ImportValidationError("PDF requires an explicit m/d/y or d/m/y date order")
    candidates: list[ImportCandidate] = []
    pattern = re.compile(
        r"^\s*([0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4})\s+(.+?)\s+([+-](?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?|\((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?\))\s*$"
    )
    for line_number, line in enumerate(_extract_pdf_text(data), start=1):
        match = pattern.fullmatch(line)
        if match is None:
            continue
        if len(candidates) >= MAX_ROWS:
            raise ImportValidationError("PDF exceeds 10000 recognized transactions")
        first, second, raw_year = map(int, match.group(1).split("/"))
        year = raw_year + (2000 if raw_year < 70 else 1900) if raw_year < 100 else raw_year
        month, day = (first, second) if date_order == "mdy" else (second, first)
        try:
            occurred_on = date(year, month, day)
            raw_amount = match.group(3).replace(",", "")
            if raw_amount.startswith("("):
                raw_amount = "-" + raw_amount[1:-1]
            amount_minor = parse_minor_units(raw_amount, scale=scale)
        except (ValueError, ImportValidationError):
            raise ImportValidationError(f"Invalid date or amount at PDF line {line_number}") from None
        description = _clean_description(match.group(2), maximum=500, position=line_number)
        candidates.append(ImportCandidate(line_number, occurred_on, amount_minor, description[:150], description))
    if not candidates:
        raise ImportValidationError(
            "PDF contains no unambiguous signed transaction rows; use CSV, OFX/QFX, QIF, or a text-based statement with signed amounts"
        )
    return candidates
