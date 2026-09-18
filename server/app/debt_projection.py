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
Strategy = Literal["avalanche", "snowball", "custom"]
MAX_MONEY = (1 << 63) - 1


def _money(value: int) -> int:
    if not 0 <= value <= MAX_MONEY:
        raise ValueError("Projection amounts exceed the supported exact-money range")
    return value


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

    def __post_init__(self):
        _money(self.projected_interest_minor)
        _money(self.projected_total_cost_minor)


@dataclass(frozen=True)
class StrategyDebt:
    """One debt in a monthly household payoff scenario.

    ``planned_payment_minor`` is the amount already available for this debt each
    month. Strategy scenarios never write this assumption back to the budget.
    """

    debt_id: str
    principal_minor: int
    annual_rate_basis_points: int
    planned_payment_minor: int
    promotional_rate_basis_points: int | None = None
    promotional_ends_on: date | None = None


@dataclass(frozen=True)
class StrategyDebtResult:
    debt_id: str
    payoff_date: date | None
    payoff_month: int | None
    projected_interest_minor: int
    projected_total_paid_minor: int


@dataclass(frozen=True)
class StrategyProjectionResult:
    status: Literal["paid_off", "non_amortizing", "iteration_limit"]
    strategy: Strategy
    rollover: bool
    payoff_order: tuple[str, ...]
    debt_free_date: date | None
    payment_count: int
    projected_interest_minor: int
    projected_total_paid_minor: int
    projected_total_cost_minor: int
    debts: tuple[StrategyDebtResult, ...]

    def __post_init__(self):
        _money(self.projected_interest_minor)
        _money(self.projected_total_paid_minor)


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


def monthly_strategy_payment(
    terms: ProjectionTerms, principal_minor: int, first_payment_on: date
) -> int:
    """Normalize an existing payment rule to an explicit monthly scenario budget."""
    periods = _PERIODS_PER_YEAR[terms.payment_frequency]
    rate = terms.annual_rate_basis_points
    if (
        terms.promotional_rate_basis_points is not None
        and terms.promotional_ends_on is not None
        and first_payment_on <= terms.promotional_ends_on
    ):
        rate = terms.promotional_rate_basis_points
    interest = _round_ratio_half_up(principal_minor * rate, 10_000 * periods)
    periodic = _planned_payment(terms, principal_minor + interest)
    return _round_ratio_half_up(periodic * periods, 12)


def project_debt(
    principal_minor: int,
    first_payment_on: date,
    terms: ProjectionTerms,
    *,
    extra_payment_minor: int = 0,
    max_periods: int = MAX_PROJECTION_PERIODS,
) -> ProjectionResult:
    _money(principal_minor)
    _money(extra_payment_minor)
    _money(terms.scheduled_payment_minor or 0)
    _money(terms.minimum_payment_minor or 0)
    if not 0 <= (terms.minimum_payment_rate_basis_points or 0) <= 10_000 or not 0 <= (terms.promotional_rate_basis_points or 0) <= 100_000:
        raise ValueError("invalid projection rate")
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
        statement = _money(principal + interest)
        planned = _money(_planned_payment(terms, statement) + extra_payment_minor)
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


def project_debt_strategy(
    debts: list[StrategyDebt] | tuple[StrategyDebt, ...],
    first_payment_on: date,
    *,
    strategy: Strategy,
    rollover: bool,
    extra_payment_minor: int = 0,
    custom_order: list[str] | tuple[str, ...] = (),
    max_periods: int = MAX_PROJECTION_PERIODS,
) -> StrategyProjectionResult:
    """Project a monthly multi-debt strategy without mutating financial truth.

    Every active debt first receives its existing planned payment. The scenario's
    extra amount is then applied in the selected order. With rollover enabled,
    the planned payment of a paid debt becomes additional strategy money beginning
    the following month. Any unused amount from a final capped payment cascades in
    the same month so scenario money is not silently discarded.
    """

    if strategy not in {"avalanche", "snowball", "custom"} or not debts or extra_payment_minor < 0 or not 1 <= max_periods <= MAX_PROJECTION_PERIODS:
        raise ValueError("invalid strategy projection input")
    _money(extra_payment_minor)
    for debt in debts:
        _money(debt.principal_minor)
        _money(debt.planned_payment_minor)
    ids = [item.debt_id for item in debts]
    if any(not item.debt_id or item.principal_minor < 0 or item.planned_payment_minor < 0 or not 0 <= item.annual_rate_basis_points <= 100_000 for item in debts):
        raise ValueError("invalid strategy debt")
    if any(not 0 <= (item.promotional_rate_basis_points or 0) <= 100_000
           or (item.promotional_rate_basis_points is None) != (item.promotional_ends_on is None) for item in debts):
        raise ValueError("invalid promotional terms")
    if len(set(ids)) != len(ids):
        raise ValueError("strategy debt IDs must be unique")
    custom = tuple(custom_order)
    if strategy == "custom" and (len(custom) != len(ids) or set(custom) != set(ids)):
        raise ValueError("custom order must contain every debt exactly once")

    balances = {item.debt_id: item.principal_minor for item in debts}
    def rates_on(payment_date: date) -> dict[str, int]:
        return {item.debt_id: item.promotional_rate_basis_points
                if item.promotional_ends_on is not None and payment_date <= item.promotional_ends_on
                else item.annual_rate_basis_points for item in debts}
    rates = rates_on(first_payment_on)
    payments = {item.debt_id: item.planned_payment_minor for item in debts}
    interest_by_id = {item.debt_id: 0 for item in debts}
    paid_by_id = {item.debt_id: 0 for item in debts}
    payoff_dates: dict[str, date] = {}
    payoff_months: dict[str, int] = {}
    payoff_order: list[str] = []
    payment_date = first_payment_on
    rollover_pool = 0

    def priority(active: list[str]) -> list[str]:
        if strategy == "avalanche":
            return sorted(active, key=lambda item: (-rates[item], balances[item], item))
        if strategy == "snowball":
            return sorted(active, key=lambda item: (balances[item], -rates[item], item))
        position = {item: index for index, item in enumerate(custom)}
        return sorted(active, key=position.__getitem__)

    initially_paid = [item for item in ids if balances[item] == 0]
    for item in priority(initially_paid):
        payoff_order.append(item)
        payoff_dates[item] = first_payment_on
        payoff_months[item] = 0

    if len(initially_paid) == len(ids):
        results = tuple(StrategyDebtResult(item, first_payment_on, 0, 0, 0) for item in ids)
        return StrategyProjectionResult(
            "paid_off", strategy, rollover, tuple(payoff_order), first_payment_on, 0, 0, 0, 0, results
        )

    for number in range(1, max_periods + 1):
        rates = rates_on(payment_date)
        active = [item for item in ids if balances[item] > 0]
        if not active:
            break
        starting_total = _money(sum(balances[item] for item in active))
        statements: dict[str, int] = {}
        for item in active:
            interest = _round_ratio_half_up(balances[item] * rates[item], 10_000 * 12)
            interest_by_id[item] += interest
            statements[item] = _money(balances[item] + interest)

        # Existing planned payments remain assigned to their debts. Rollover is
        # added only after a debt is gone, never while it still has a balance.
        remaining = dict(statements)
        for item in active:
            payment = min(payments[item], remaining[item])
            remaining[item] -= payment
            paid_by_id[item] += payment

        strategy_money = _money(extra_payment_minor + (rollover_pool if rollover else 0))
        for item in priority([value for value in active if remaining[value] > 0]):
            payment = min(strategy_money, remaining[item])
            remaining[item] -= payment
            paid_by_id[item] += payment
            strategy_money -= payment
            if strategy_money == 0:
                break

        newly_paid: list[str] = []
        for item in active:
            balances[item] = remaining[item]
            if balances[item] == 0:
                newly_paid.append(item)
                payoff_dates[item] = payment_date
                payoff_months[item] = number
        for item in priority(newly_paid):
            payoff_order.append(item)
            if rollover:
                rollover_pool = _money(rollover_pool + payments[item])

        if all(value == 0 for value in balances.values()):
            results = tuple(
                StrategyDebtResult(item, payoff_dates.get(item), payoff_months.get(item), interest_by_id[item], paid_by_id[item])
                for item in ids
            )
            total_interest = sum(interest_by_id.values())
            total_paid = sum(paid_by_id.values())
            return StrategyProjectionResult("paid_off", strategy, rollover, tuple(payoff_order), payment_date, number, total_interest, total_paid, total_paid, results)

        # If aggregate principal did not decline, the fixed household payment
        # budget cannot amortize this scenario. Return an explicit typed result
        # instead of manufacturing a debt-free date.
        upcoming_rate_change = any(balances[item.debt_id] > 0 and item.promotional_ends_on is not None
                                   and payment_date <= item.promotional_ends_on for item in debts)
        if _money(sum(balances.values())) >= starting_total and not newly_paid and not upcoming_rate_change:
            results = tuple(
                StrategyDebtResult(item, payoff_dates.get(item), payoff_months.get(item), interest_by_id[item], paid_by_id[item])
                for item in ids
            )
            total_interest = sum(interest_by_id.values())
            total_paid = sum(paid_by_id.values())
            return StrategyProjectionResult("non_amortizing", strategy, rollover, tuple(payoff_order), None, number, total_interest, total_paid, total_paid, results)
        payment_date = _advance(payment_date, "monthly")

    results = tuple(
        StrategyDebtResult(item, payoff_dates.get(item), payoff_months.get(item), interest_by_id[item], paid_by_id[item])
        for item in ids
    )
    total_interest = sum(interest_by_id.values())
    total_paid = sum(paid_by_id.values())
    status: Literal["paid_off", "non_amortizing", "iteration_limit"] = "iteration_limit"
    if total_paid == 0 or all(payments[item] == 0 for item in ids) and extra_payment_minor == 0:
        status = "non_amortizing"
    return StrategyProjectionResult(status, strategy, rollover, tuple(payoff_order), None, max_periods, total_interest, total_paid, total_paid, results)
