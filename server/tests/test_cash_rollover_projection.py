import json
from datetime import date
from pathlib import Path

import pytest

from app.cash_rollover import CategoryFact, PolicyChange, project_rollover_effects

VECTORS = json.loads((Path(__file__).parent / "financial_vectors/cash-rollover-v1.json").read_text())["cases"]


@pytest.mark.parametrize("case", VECTORS, ids=lambda case: case["id"])
def test_shared_rollover_projection_vectors(case):
    policies = [PolicyChange(date.fromisoformat(month), policy, version) for month, policy, version in case["policies"]]
    facts = [CategoryFact(date.fromisoformat(day), category, amount, credit) for day, category, amount, credit in case["facts"]]
    def project(items=facts):
        return project_rollover_effects(through_month=date.fromisoformat(case["through"]), policies=policies, facts=items)
    if "error" in case:
        with pytest.raises(OverflowError):
            project()
        return
    result = project()
    assert [[item.month.isoformat(), item.category_id, item.amount_minor, item.policy_version] for item in result] == case["effects"]
    assert project() == result
    assert project(list(reversed(facts))) == result
    # A later policy entry cannot change observations/effects before its effective period.
    for month, *_ in case["policies"]:
        boundary = date.fromisoformat(month)
        prior = [item for item in policies if item.effective_month < boundary]
        earlier_months = {item.occurred_on.replace(day=1) for item in facts if item.occurred_on.replace(day=1) < boundary}
        for earlier in earlier_months:
            assert project_rollover_effects(through_month=earlier, policies=policies, facts=facts) == project_rollover_effects(through_month=earlier, policies=prior, facts=facts)


@pytest.mark.parametrize("changes", [
    [PolicyChange(date(2026, 10, 2), "absorb_next_month", 0)],
    [PolicyChange(date(2026, 10, 1), "unknown", 0)],
    [PolicyChange(date(2026, 10, 1), "absorb_next_month", -1)],
    [PolicyChange(date(2026, 10, 1), "absorb_next_month", 0), PolicyChange(date(2026, 11, 1), "carry_category_deficit", 0)],
])
def test_invalid_policy_history_is_not_silently_reinterpreted(changes):
    with pytest.raises(ValueError):
        project_rollover_effects(through_month=date(2026, 12, 1), policies=changes, facts=[])


@pytest.mark.parametrize("amount", [1.5, True, "100"])
def test_rollover_does_not_accept_inexact_or_coerced_money(amount):
    with pytest.raises(ValueError, match="exact integer"):
        project_rollover_effects(through_month=date(2026, 10, 1), policies=[], facts=[CategoryFact(date(2026, 9, 1), "food", amount)])


def test_actual_history_edit_recalculates_effect_without_rewriting_policy():
    history = [PolicyChange(date(2026, 9, 1), "absorb_next_month", 0), PolicyChange(date(2026, 11, 1), "carry_category_deficit", 1)]
    def project(amount):
        return project_rollover_effects(through_month=date(2026, 12, 1), policies=history, facts=[CategoryFact(date(2026, 9, 30), "food", amount)])
    assert project(-5000)[0].amount_minor == 5000
    edited = project(-3000)
    assert edited[0].amount_minor == 3000
    assert edited[0].policy_version == 0
    assert project(-3000) == edited
