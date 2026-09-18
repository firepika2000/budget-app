from __future__ import annotations

from calendar import monthrange
from dataclasses import dataclass
from datetime import date, timedelta

from .models import CategoryTarget, ScheduledTransaction


def add_months(value: date, months: int) -> date:
    month_index = value.year * 12 + value.month - 1 + months
    year, zero_based_month = divmod(month_index, 12)
    month = zero_based_month + 1
    return date(year, month, min(value.day, monthrange(year, month)[1]))


def next_occurrence(value: date, unit: str, interval: int) -> date | None:
    if unit == "once":
        return None
    if unit == "days":
        return value + timedelta(days=interval)
    if unit == "weeks":
        return value + timedelta(weeks=interval)
    if unit == "months":
        return add_months(value, interval)
    if unit == "years":
        return add_months(value, interval * 12)
    raise ValueError(f"Unsupported recurrence unit: {unit}")


def occurrences_between(
    schedule: ScheduledTransaction,
    start: date,
    through: date,
) -> list[date]:
    result: list[date] = []
    occurrence = schedule.next_date
    for _ in range(1000):
        if occurrence > through:
            break
        if occurrence >= start:
            result.append(occurrence)
        following = next_occurrence(occurrence, schedule.recurrence_unit, schedule.interval_count)
        if following is None:
            break
        occurrence = following
    else:
        raise ValueError("Schedule produces too many forecast occurrences")
    return result


@dataclass(frozen=True)
class TargetFunding:
    recommended_contribution_minor: int
    underfunded_minor: int
    effective_target_date: date | None = None


def target_occurrence(target: CategoryTarget, month: date) -> tuple[int, date | None]:
    """Advance from the immutable anchor, by planning month, not elapsed days.

    Beyond the supported date range retain exact period guidance but omit an
    unrepresentable display date. Never clamp an occurrence to a false deadline.
    """
    anchor = target.target_date
    if anchor is None:
        return 1, None
    delta = (month.year - anchor.year) * 12 + month.month - anchor.month
    offset = 0
    if target.target_type == "recurring_expense" and delta > 0:
        cadence = target.recurrence_months
        if cadence is None or cadence <= 0:
            raise ValueError("Recurring target requires a positive cadence")
        offset = ((delta + cadence - 1) // cadence) * cadence
    periods = max(1, offset - delta + 1)
    due_year = (anchor.year * 12 + anchor.month - 1 + offset) // 12
    return periods, add_months(anchor, offset) if due_year <= 9999 else None


def target_funding(
    target: CategoryTarget,
    *,
    month: date,
    assigned_minor: int,
    available_minor: int,
) -> TargetFunding:
    periods, due = target_occurrence(target, month)
    if not target.is_active:
        return TargetFunding(0, 0, due)
    if target.target_type == "monthly_funding":
        recommendation = max(target.target_amount_minor, target.minimum_contribution_minor)
    elif target.target_type == "savings_balance":
        recommendation = max(
            target.target_amount_minor - max(available_minor - assigned_minor, 0),
            target.minimum_contribution_minor,
        )
    else:
        gap = max(target.target_amount_minor - max(available_minor - assigned_minor, 0), 0)
        recommendation = max((gap + periods - 1) // periods, target.minimum_contribution_minor)
    return TargetFunding(
        recommended_contribution_minor=recommendation,
        underfunded_minor=max(recommendation - max(assigned_minor, 0), 0),
        effective_target_date=due,
    )
