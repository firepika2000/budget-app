"""Deterministic debt payoff projection using integer minor units only.

APR is stored in basis points.  Each payment period accrues simple periodic interest as
``principal_minor * annual_rate_basis_points / (10_000 * periods_per_year)`` and rounds
half up to one minor unit before the payment is applied.  Payments occur at the end of
each period; the final payment is capped to principal plus that period's interest.

This is a scenario model, not an issuer statement reconstruction: it deliberately does
not guess daily-balance, grace-period, fee, or issuer-specific minimum-payment rules.
"""

from __future__ import annotations

from calendar import monthrange
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Literal


Frequency = Literal["weekly", "biweekly", "monthly"]
PaymentRule = Literal["fixed", "percentage", "greater_of"]


@dataclass(frozen=True)
class ProjectionTerms:
    annual_rate_basis_points: int
    payment_frequency: Frequency
    scheduled_payment_minor: int | None = None
    minimum_payment_rule: PaymentRule | None = None
    minimum_payment_minor: int | None = None
    minimum_payment_rate_basis_points: int | None = None
    promotional_rate_basis_points: int | None = None
    promotional_ends_on: date | None = None


@dataclass(frozen=True)
class ProjectionPoint:
    payment_number: int
    payment_date: date
    starting_principal_minor: int
    interest_minor: int
    payment_minor: int
    ending_principal_minor: int


@dataclass(frozen=True)
class ProjectionResult:
    status: Literal["paid_off", "non_amortizing", "iteration_limit"]
    payoff_date: date | None
    payment_count: int
    projected_interest_minor: int
    projected_total_cost_minor: int
    points: tuple[ProjectionPoint, ...]


MAX_PROJECTION_PERIODS = 1_200
_PERIODS_PER_YEAR: dict[Frequency, int] = {"weekly": 52, "biweekly": 26, "monthly": 12}


def _round_ratio_half_up(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise ValueError("projection ratios require non-negative values")
    return (numerator + denominator // 2) // denominator


def _advance(value: date, frequency: Frequency) -> date:
    if frequency == "weekly":
        return value + timedelta(days=7)
    if frequency == "biweekly":
        return value + timedelta(days=14)
    month_index = value.year * 12 + value.month
    year, zero_based_month = divmod(month_index, 12)
    month = zero_based_month + 1
    return date(year, month, min(value.day, monthrange(year, month)[1]))


def _planned_payment(terms: ProjectionTerms, statement_minor: int) -> int:
    if terms.scheduled_payment_minor is not None:
        return terms.scheduled_payment_minor
    percentage = _round_ratio_half_up(
        statement_minor * (terms.minimum_payment_rate_basis_points or 0), 10_000
    )
    if terms.minimum_payment_rule == "fixed":
        return terms.minimum_payment_minor or 0
    if terms.minimum_payment_rule == "percentage":
        return percentage
    if terms.minimum_payment_rule == "greater_of":
        return max(terms.minimum_payment_minor or 0, percentage)
    raise ValueError("terms do not define a payment rule")


def project_debt(
    principal_minor: int,
    first_payment_on: date,
    terms: ProjectionTerms,
    *,
    extra_payment_minor: int = 0,
    max_periods: int = MAX_PROJECTION_PERIODS,
) -> ProjectionResult:
    if principal_minor < 0 or extra_payment_minor < 0 or not 0 <= terms.annual_rate_basis_points <= 100_000:
        raise ValueError("invalid projection input")
    if max_periods < 1 or max_periods > MAX_PROJECTION_PERIODS:
        raise ValueError("invalid projection bound")
    if principal_minor == 0:
        return ProjectionResult("paid_off", first_payment_on, 0, 0, 0, ())

    principal = principal_minor
    payment_date = first_payment_on
    total_interest = 0
    total_paid = 0
    points: list[ProjectionPoint] = []
    periods = _PERIODS_PER_YEAR[terms.payment_frequency]

    for number in range(1, max_periods + 1):
        rate = terms.annual_rate_basis_points
        if terms.promotional_rate_basis_points is not None and terms.promotional_ends_on is not None and payment_date <= terms.promotional_ends_on:
            rate = terms.promotional_rate_basis_points
        interest = _round_ratio_half_up(principal * rate, 10_000 * periods)
        statement = principal + interest
        planned = _planned_payment(terms, statement) + extra_payment_minor
        if planned <= interest:
            return ProjectionResult("non_amortizing", None, number - 1, total_interest, total_paid, tuple(points))
        payment = min(planned, statement)
        ending = statement - payment
        points.append(ProjectionPoint(number, payment_date, principal, interest, payment, ending))
        total_interest += interest
        total_paid += payment
        if ending == 0:
            return ProjectionResult("paid_off", payment_date, number, total_interest, total_paid, tuple(points))
        principal = ending
        payment_date = _advance(payment_date, terms.payment_frequency)

    return ProjectionResult("iteration_limit", None, max_periods, total_interest, total_paid, tuple(points))
