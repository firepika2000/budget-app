"""Pure, sparse month-boundary projection; never posts or mutates financial records.

Activation remains gated on all repository balance guards/report consumers using these effects.
Inputs are canonical category activity/allocations and signed unfunded-credit attribution:
credit-category activity + its recorded funding/release events (not a guessed deficit share).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date

MAX_MINOR = 2**63 - 1
MIN_MINOR = -(2**63)
POLICIES = {"carry_category_deficit", "absorb_next_month"}


@dataclass(frozen=True)
class PolicyChange:
    effective_month: date
    policy: str
    version: int


@dataclass(frozen=True)
class CategoryFact:
    occurred_on: date
    category_id: str
    available_delta_minor: int
    unfunded_credit_delta_minor: int = 0


@dataclass(frozen=True)
class RolloverEffect:
    month: date
    category_id: str
    amount_minor: int
    policy_version: int


def _checked(value: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError("Rollover money must be exact integer minor units")
    if not MIN_MINOR <= value <= MAX_MINOR:
        raise OverflowError("Rollover observation exceeds supported minor units")
    return value


def _next_month(month: date) -> date | None:
    if month == date(9999, 12, 1):
        return None
    return date(month.year + (month.month == 12), month.month % 12 + 1, 1)


def project_rollover_effects(*, through_month: date, policies: list[PolicyChange], facts: list[CategoryFact]) -> list[RolloverEffect]:
    if through_month.day != 1:
        raise ValueError("Rollover horizon must be a month start")
    if len({item.version for item in policies}) != len(policies):
        raise ValueError("Duplicate policy version")
    for item in policies:
        if (item.effective_month.day != 1 or not isinstance(item.version, int)
                or isinstance(item.version, bool) or item.version < 0 or item.policy not in POLICIES):
            raise ValueError("Invalid rollover policy history")
    history = sorted(policies, key=lambda item: (item.effective_month, item.version))
    by_month: dict[date, list[CategoryFact]] = {}
    boundaries = {item.effective_month for item in history if item.effective_month <= through_month}
    for item in facts:
        _checked(item.available_delta_minor)
        _checked(item.unfunded_credit_delta_minor)
        month = item.occurred_on.replace(day=1)
        if month > through_month:
            continue
        by_month.setdefault(month, []).append(item)
        boundaries.add(month)
        following = _next_month(month)
        if following is not None and following <= through_month:
            boundaries.add(following)
    available: dict[str, int] = {}
    credit: dict[str, int] = {}
    effects = []
    index = 0
    policy = None
    for month in sorted(boundaries):
        while index < len(history) and history[index].effective_month <= month:
            policy = history[index]
            index += 1
        # Apply the boundary BEFORE this month's user assignment/activity. No effect is
        # Assigned or Activity; consumers add it to carry and debit Unassigned exactly once.
        if policy is not None and policy.policy == "absorb_next_month":
            for category in sorted(available):
                cash_deficit = max(min(_checked(credit.get(category, 0)), 0) - _checked(available[category]), 0)
                if cash_deficit:
                    _checked(cash_deficit)
                    available[category] = _checked(available[category] + cash_deficit)
                    effects.append(RolloverEffect(month, category, cash_deficit, policy.version))
        for item in by_month.get(month, []):
            available[item.category_id] = available.get(item.category_id, 0) + item.available_delta_minor
            credit[item.category_id] = credit.get(item.category_id, 0) + item.unfunded_credit_delta_minor
        # Sum a whole month exactly before checking its published boundary state: input
        # ordering cannot turn a representable cancelling total into an intermediate trap.
        for value in available.values():
            _checked(value)
        for value in credit.values():
            _checked(value)
    return effects
