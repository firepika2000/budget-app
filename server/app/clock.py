"""Wall-clock boundary for date-sensitive application services."""

from datetime import date


def today() -> date:
    return date.today()
