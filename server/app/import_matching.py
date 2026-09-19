"""Pure import review suggestions, never approval or authorization.

Adapters MUST scope observations to the current actor, budget and target account
before invoking this module. It has no database access and cannot enforce that
boundary itself. No match, including a unique exact match, authorizes mutation.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date

from .import_candidates import ImportCandidate, ImportValidationError, MAX_ROWS
from .payee_names import normalized_payee_name


MAX_OBSERVATIONS = 50_000
MAX_SUGGESTIONS = 20


@dataclass(frozen=True)
class MatchObservation:
    transaction_id: str
    occurred_on: date
    amount_minor: int
    payee: str


@dataclass(frozen=True)
class CandidateReview:
    source_row: int
    exact_transaction_ids: tuple[str, ...]
    possible_transaction_ids: tuple[str, ...]
    suggestions_truncated: bool
    duplicate_source_row: int | None


def review_candidates(
    candidates: list[ImportCandidate], observations: list[MatchObservation], *, date_window_days: int = 0,
) -> list[CandidateReview]:
    """Exact = same amount/date/normalized name; possible = same amount in window.

    Deterministic date/ID ordering, bounded output, no greedy match consumption:
    repeated legitimate purchases remain distinguishable during explicit review.
    """
    if type(date_window_days) is not int or not 0 <= date_window_days <= 7:
        raise ImportValidationError("Match date window must be between zero and seven days")
    if len(candidates) > MAX_ROWS or len(observations) > MAX_OBSERVATIONS:
        raise ImportValidationError("Matching input exceeds supported batch size")
    if len({row.source_row for row in candidates}) != len(candidates):
        raise ImportValidationError("Candidate source rows must be unique")
    if len({row.transaction_id for row in observations}) != len(observations):
        raise ImportValidationError("Transaction observations must be unique")
    # Each bucket retains only the first page and total count. Never materialize
    # a candidate x history cross product for common repeated amounts.
    buckets = defaultdict(list)
    exact_buckets = defaultdict(list)
    counts = defaultdict(int)
    for row in sorted(observations, key=lambda row: row.transaction_id):
        key = (row.amount_minor, row.occurred_on.toordinal())
        exact_key = (*key, normalized_payee_name(row.payee))
        counts[key] += 1
        if len(buckets[key]) < MAX_SUGGESTIONS:
            buckets[key].append(row.transaction_id)
        if len(exact_buckets[exact_key]) < MAX_SUGGESTIONS:
            exact_buckets[exact_key].append(row.transaction_id)
    seen = {}
    result = []
    for row in candidates:
        day = row.occurred_on.toordinal()
        key = (row.amount_minor, day, normalized_payee_name(row.payee))
        exact = tuple(exact_buckets[key])
        possible = []
        total = 0
        for offset in sorted(range(-date_window_days, date_window_days + 1), key=lambda value: (abs(value), value)):
            bucket_key = (row.amount_minor, day + offset)
            total += counts[bucket_key]
            possible.extend(identifier for identifier in buckets[bucket_key] if identifier not in exact)
        fingerprint = (*key, row.memo)
        duplicate = seen.get(fingerprint)
        seen.setdefault(fingerprint, row.source_row)
        result.append(CandidateReview(row.source_row, exact, tuple(possible[:MAX_SUGGESTIONS]),
                                      total > len(exact) + min(len(possible), MAX_SUGGESTIONS), duplicate))
    return result
