from datetime import date

import pytest

from app.import_candidates import ImportCandidate, ImportValidationError
from app.import_matching import MatchObservation, review_candidates


DAY = date(2026, 9, 18)


def candidate(row=2, amount=-100, memo=""):
    return ImportCandidate(row, DAY, amount, " Café ", memo)


def test_exact_possible_refunds_and_repeated_candidates_are_not_auto_consumed():
    observations = [MatchObservation("b", DAY, -100, "Other"), MatchObservation("a", DAY, -100, "CAFÉ"), MatchObservation("refund", DAY, 100, "Café")]
    reviews = review_candidates([candidate(), candidate(3), candidate(4, 100)], observations)
    assert reviews[0].exact_transaction_ids == ("a",)
    assert reviews[0].possible_transaction_ids == ("b",)
    assert reviews[1].exact_transaction_ids == ("a",)
    assert reviews[1].duplicate_source_row == 2
    assert reviews[2].exact_transaction_ids == ("refund",)
    assert reviews[2].duplicate_source_row is None


def test_date_window_is_explicit_and_deterministic():
    observations = [MatchObservation("next", date(2026, 9, 19), -100, "Café"), MatchObservation("prior", date(2026, 9, 17), -100, "Café")]
    assert review_candidates([candidate()], observations)[0].possible_transaction_ids == ()
    assert review_candidates([candidate()], observations, date_window_days=1)[0].possible_transaction_ids == ("prior", "next")
    assert review_candidates([candidate()], observations, date_window_days=1) == review_candidates([candidate()], observations[::-1], date_window_days=1)


def test_large_repeated_dataset_has_bounded_suggestions():
    observations = [MatchObservation(f"t{index:05d}", DAY, -100, "Café") for index in range(50_000)]
    reviews = review_candidates([candidate(index + 2) for index in range(10_000)], observations)
    assert len(reviews) == 10_000
    assert all(len(row.exact_transaction_ids) == 20 and row.suggestions_truncated for row in reviews)
    assert all(not row.possible_transaction_ids for row in reviews)


def test_duplicate_warning_preserves_distinct_memo_and_no_history_is_no_match():
    reviews = review_candidates([candidate(), candidate(3, memo="Different")], [])
    assert all(not row.exact_transaction_ids and row.duplicate_source_row is None for row in reviews)


def test_duplicate_ids_and_invalid_window_refused():
    with pytest.raises(ImportValidationError):
        review_candidates([candidate(), candidate()], [])
    item = MatchObservation("one", DAY, -100, "Café")
    with pytest.raises(ImportValidationError):
        review_candidates([], [item, item])
    with pytest.raises(ImportValidationError):
        review_candidates([], [], date_window_days=8)
