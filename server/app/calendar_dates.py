"""Inclusive Gregorian periods without constructing dates outside Python's supported calendar."""

from calendar import monthrange
from collections.abc import Iterator
from datetime import date, timedelta


def month_end(value: date) -> date:
    return value.replace(day=monthrange(value.year, value.month)[1])


def month_periods(start: date, end: date) -> Iterator[tuple[date, date]]:
    cursor = start
    while cursor <= end:
        through = min(month_end(cursor), end)
        yield cursor, through
        if through == end:
            return
        cursor = through + timedelta(days=1)
