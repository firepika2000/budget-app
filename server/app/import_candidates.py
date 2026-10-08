"""Untrusted file input -> money-neutral candidates; never an accounting writer.

The caller must obtain currency scale from authoritative budget configuration.
No locale guessing, payee creation, matching, or posting happens here.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass
from datetime import date


MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_ROWS = 10_000
MAX_COLUMNS = 100
MAX_FIELD_CHARS = 4_096


class ImportValidationError(ValueError):
    """Safe error messages contain positions, never financial file contents."""


@dataclass(frozen=True)
class CSVMapping:
    date_column: str
    amount_column: str | None
    payee_column: str
    memo_column: str | None = None
    debit_column: str | None = None
    credit_column: str | None = None
    date_order: str = "ymd"
    delimiter: str = ","
    number_format: str = "dot_decimal"

    def validate(self) -> None:
        signed = self.amount_column is not None
        split = self.debit_column is not None and self.credit_column is not None
        if signed == split or (signed and (self.debit_column is not None or self.credit_column is not None)):
            raise ImportValidationError("Select one signed amount column or both debit and credit columns")
        if self.date_order not in {"ymd", "mdy", "dmy"}:
            raise ImportValidationError("Unsupported date order")
        if self.delimiter not in {",", ";", "\t"}:
            raise ImportValidationError("Unsupported delimiter")
        if self.number_format not in {"dot_decimal", "comma_decimal"}:
            raise ImportValidationError("Unsupported number format")


@dataclass(frozen=True)
class ImportCandidate:
    source_row: int
    occurred_on: date
    amount_minor: int
    payee: str
    memo: str


def parse_minor_units(value: str, *, scale: int) -> int:
    if type(scale) is not int or not 0 <= scale <= 6:
        raise ImportValidationError("Unsupported currency scale")
    value = value.strip()
    if len(value) > 40 or not re.fullmatch(r"[+-]?[0-9]+(?:\.[0-9]+)?", value):
        raise ImportValidationError("Amount must be a plain decimal number")
    negative = value.startswith("-")
    whole, _, fraction = value.lstrip("+-").partition(".")
    if len(fraction) > scale:
        raise ImportValidationError("Amount exceeds currency precision")
    minor = int(whole) * 10**scale + int(fraction.ljust(scale, "0") or "0")
    if negative:
        minor = -minor
    if not -(2**63) <= minor <= 2**63 - 1:
        raise ImportValidationError("Amount exceeds supported range")
    return minor


def parse_mapped_minor_units(value: str, *, scale: int, number_format: str) -> int:
    """Parse an explicitly selected CSV number convention without locale guessing."""
    value = value.strip()
    if number_format == "dot_decimal":
        pattern = r"[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?"
        normalized = value.replace(",", "")
    elif number_format == "comma_decimal":
        pattern = r"[+-]?(?:[0-9]+|[0-9]{1,3}(?:\.[0-9]{3})+)(?:,[0-9]+)?"
        normalized = value.replace(".", "").replace(",", ".")
    else:
        raise ImportValidationError("Unsupported number format")
    if len(value) > 40 or not re.fullmatch(pattern, value):
        raise ImportValidationError("Amount does not match the selected number format")
    return parse_minor_units(normalized, scale=scale)


def parse_mapped_date(value: str, *, date_order: str) -> date:
    """Parse a selected field order while accepting common, internally consistent separators."""
    value = value.strip()
    if date_order == "ymd":
        match = re.fullmatch(r"([0-9]{4})([-/.])([0-9]{1,2})\2([0-9]{1,2})", value)
        if match is None:
            raise ValueError()
        year, month, day = int(match[1]), int(match[3]), int(match[4])
    elif date_order in {"mdy", "dmy"}:
        match = re.fullmatch(r"([0-9]{1,2})([-/.])([0-9]{1,2})\2([0-9]{4})", value)
        if match is None:
            raise ValueError()
        first, second, year = int(match[1]), int(match[3]), int(match[4])
        month, day = (first, second) if date_order == "mdy" else (second, first)
    else:
        raise ValueError()
    return date(year, month, day)


def parse_csv_candidates(data: bytes, mapping: CSVMapping, *, scale: int) -> list[ImportCandidate]:
    # Validate even empty inputs; no global csv.field_size_limit mutation.
    parse_minor_units("0", scale=scale)
    mapping.validate()
    if len(data) > MAX_FILE_BYTES:
        raise ImportValidationError("File exceeds 10 MB")
    try:
        # Spreadsheet exports commonly use UTF-16. Accept it only when a BOM makes the
        # byte order explicit; otherwise retain UTF-8 as the deterministic default.
        text = data.decode("utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
    except UnicodeDecodeError:
        raise ImportValidationError("CSV must use UTF-8 or BOM-marked UTF-16 encoding") from None
    if "\x00" in text:
        if not data.startswith((b"\xff\xfe", b"\xfe\xff")):
            raise ImportValidationError("CSV must use UTF-8 or BOM-marked UTF-16 encoding")
        raise ImportValidationError("CSV contains an unsupported control character")
    reader = csv.reader(io.StringIO(text, newline=""), strict=True, delimiter=mapping.delimiter)
    candidates = []
    try:
        header = next(reader, [])
        if not header or len(header) > MAX_COLUMNS or any(not h or len(h) > MAX_FIELD_CHARS for h in header) or len(set(header)) != len(header):
            raise ImportValidationError("CSV requires unique nonempty column names")
        selected = [mapping.date_column, mapping.payee_column]
        selected.extend(name for name in [mapping.amount_column, mapping.debit_column, mapping.credit_column] if name is not None)
        if mapping.memo_column is not None:
            selected.append(mapping.memo_column)
        if len(set(selected)) != len(selected) or any(name not in header for name in selected):
            raise ImportValidationError("Column mapping must select distinct existing columns")
        indexes = {name: header.index(name) for name in selected}
        for row_number, row in enumerate(reader, start=2):
            if len(candidates) >= MAX_ROWS:
                raise ImportValidationError("CSV exceeds 10000 data rows")
            if len(row) != len(header) or any(len(field) > MAX_FIELD_CHARS for field in row):
                raise ImportValidationError(f"Invalid column count or field size at row {row_number}")
            raw_date = row[indexes[mapping.date_column]].strip()
            try:
                occurred_on = parse_mapped_date(raw_date, date_order=mapping.date_order)
                if mapping.amount_column is not None:
                    amount = parse_mapped_minor_units(row[indexes[mapping.amount_column]], scale=scale, number_format=mapping.number_format)
                else:
                    debit_text = row[indexes[mapping.debit_column]].strip()
                    credit_text = row[indexes[mapping.credit_column]].strip()
                    if not debit_text and not credit_text:
                        raise ValueError()
                    debit = parse_mapped_minor_units(debit_text or "0", scale=scale, number_format=mapping.number_format)
                    credit = parse_mapped_minor_units(credit_text or "0", scale=scale, number_format=mapping.number_format)
                    if debit < 0 or credit < 0 or (debit and credit):
                        raise ValueError()
                    amount = credit - debit
            except ValueError:
                raise ImportValidationError(f"Invalid date or amount at row {row_number}") from None
            payee = row[indexes[mapping.payee_column]].strip()
            memo = row[indexes[mapping.memo_column]] if mapping.memo_column is not None else ""
            if len(payee) > 150 or len(memo) > 500:
                raise ImportValidationError(f"Payee or memo exceeds supported length at row {row_number}")
            candidates.append(ImportCandidate(row_number, occurred_on, amount, payee, memo))
    except csv.Error:
        raise ImportValidationError("Malformed CSV") from None
    return candidates
