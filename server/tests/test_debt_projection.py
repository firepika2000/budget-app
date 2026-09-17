from datetime import date

import pytest

from app.debt_projection import ProjectionTerms, StrategyDebt, project_debt, project_debt_strategy
from .conftest import auth
from .test_budgeting_api import create_budget


def loan(*, rate=0, payment=1000, frequency="monthly", **values):
    return ProjectionTerms(
        annual_rate_basis_points=rate, payment_frequency=frequency,
        scheduled_payment_minor=payment, **values,
    )


def card(*, rate=0, fixed=1000, **values):
    return ProjectionTerms(
        annual_rate_basis_points=rate, payment_frequency="monthly",
        minimum_payment_rule="fixed", minimum_payment_minor=fixed, **values,
    )


def test_zero_apr_and_final_partial_payment_are_exact():
    result = project_debt(2501, date(2026, 1, 31), loan(payment=1000))
    assert result.status == "paid_off"
    assert result.payment_count == 3
    assert result.payoff_date == date(2026, 3, 28)
    assert result.projected_interest_minor == 0
    assert result.projected_total_cost_minor == 2501
    assert [point.payment_minor for point in result.points] == [1000, 1000, 501]


def test_interest_rounds_half_up_each_period_without_float_accumulation():
    # $100.00 at 12% APR accrues exactly $1.00 for the first monthly period.
    result = project_debt(10_000, date(2026, 2, 28), loan(rate=1200, payment=5000))
    assert result.points[0].interest_minor == 100
    assert result.projected_interest_minor == 153
    assert result.projected_total_cost_minor == 10_153


@pytest.mark.parametrize("extra,expected_count,expected_interest", [(0, 12, 654), (5000, 2, 142), (10000, 1, 100), (25000, 1, 100)])
def test_extra_payment_presets_reduce_time_and_interest(extra, expected_count, expected_interest):
    result = project_debt(10_000, date(2026, 1, 15), card(rate=1200, fixed=900), extra_payment_minor=extra)
    assert result.status == "paid_off"
    assert result.payment_count == expected_count
    assert result.projected_interest_minor == expected_interest


def test_payment_not_exceeding_interest_is_explicitly_non_amortizing():
    result = project_debt(100_000, date(2026, 1, 1), card(rate=3600, fixed=3000))
    assert result.status == "non_amortizing"
    assert result.payoff_date is None and result.payment_count == 0


def test_percentage_and_greater_of_rules_are_not_issuer_guesses():
    percentage = ProjectionTerms(annual_rate_basis_points=0, payment_frequency="monthly", minimum_payment_rule="percentage", minimum_payment_rate_basis_points=1000)
    greater = ProjectionTerms(annual_rate_basis_points=0, payment_frequency="monthly", minimum_payment_rule="greater_of", minimum_payment_minor=1500, minimum_payment_rate_basis_points=1000)
    assert project_debt(10_000, date(2026, 1, 1), percentage).points[0].payment_minor == 1000
    assert project_debt(10_000, date(2026, 1, 1), greater).points[0].payment_minor == 1500


def test_promotional_rate_switches_on_explicit_period_boundary():
    terms = card(rate=2400, fixed=5000, promotional_rate_basis_points=0, promotional_ends_on=date(2026, 1, 31))
    result = project_debt(10_000, date(2026, 1, 31), terms)
    assert result.points[0].interest_minor == 0
    assert result.points[1].interest_minor == 100


def test_weekly_biweekly_month_end_and_leap_boundaries_are_deterministic():
    weekly = project_debt(2000, date(2028, 2, 22), loan(payment=1000, frequency="weekly"))
    biweekly = project_debt(2000, date(2028, 2, 15), loan(payment=1000, frequency="biweekly"))
    monthly = project_debt(2000, date(2028, 1, 31), loan(payment=1000))
    assert weekly.points[1].payment_date == date(2028, 2, 29)
    assert biweekly.points[1].payment_date == date(2028, 2, 29)
    assert monthly.points[1].payment_date == date(2028, 2, 29)


def test_iteration_bound_and_invalid_inputs_are_safe():
    limited = project_debt(1_000_000, date(2026, 1, 1), loan(payment=1000), max_periods=2)
    assert limited.status == "iteration_limit" and limited.payment_count == 2
    with pytest.raises(ValueError): project_debt(-1, date(2026, 1, 1), loan())
    with pytest.raises(ValueError): project_debt(1, date(2026, 1, 1), loan(), max_periods=1201)


def test_account_projection_endpoint_uses_authoritative_balance_terms_and_scenario_only_extra(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit", "starting_balance_minor": -10_000},
    ).json()
    projection_url = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/debt-projection"
    incomplete = client.post(
        projection_url, headers=auth(owner_token),
        json={"first_payment_on": "2026-01-15", "extra_payment_minor": 0},
    )
    assert incomplete.status_code == 200
    assert incomplete.json()["status"] == "incomplete"
    assert incomplete.json()["missing_projection_fields"] == ["debt_terms"]

    terms = client.put(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/debt-terms",
        headers=auth(owner_token), json={
            "terms_type": "credit_card", "annual_rate_basis_points": 1200,
            "rate_type": "fixed", "payment_frequency": "monthly", "due_day": 15,
            "minimum_payment_rule": "fixed", "minimum_payment_minor": 900,
        },
    )
    assert terms.status_code == 200, terms.text
    baseline = client.post(
        projection_url, headers=auth(owner_token),
        json={"first_payment_on": "2026-01-15", "extra_payment_minor": 0},
    ).json()
    faster = client.post(
        projection_url, headers=auth(owner_token),
        json={"first_payment_on": "2026-01-15", "extra_payment_minor": 5000},
    ).json()
    assert (baseline["payment_count"], baseline["projected_interest_minor"]) == (12, 654)
    assert (faster["payment_count"], faster["projected_interest_minor"]) == (2, 142)
    assert baseline["starting_principal_minor"] == faster["starting_principal_minor"] == 10_000

    # Scenario requests are read-only and never write the ledger balance or persisted terms.
    balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json()
    assert balance["working_balance_minor"] == -10_000
    persisted = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/debt-terms",
        headers=auth(owner_token),
    ).json()
    assert persisted["minimum_payment_minor"] == 900


def test_multi_debt_snowball_rollover_is_explicit_and_exact_at_zero_apr():
    debts = [
        StrategyDebt("large", 10_000, 0, 1_000),
        StrategyDebt("small", 2_000, 0, 500),
    ]
    without_rollover = project_debt_strategy(
        debts, date(2026, 1, 31), strategy="snowball", rollover=False
    )
    with_rollover = project_debt_strategy(
        debts, date(2026, 1, 31), strategy="snowball", rollover=True
    )

    assert without_rollover.status == with_rollover.status == "paid_off"
    assert without_rollover.payoff_order == with_rollover.payoff_order == ("small", "large")
    assert without_rollover.payment_count == 10
    assert with_rollover.payment_count == 8
    assert with_rollover.debt_free_date == date(2026, 8, 28)
    assert with_rollover.projected_interest_minor == 0
    assert with_rollover.projected_total_paid_minor == 12_000
    assert sum(item.projected_total_paid_minor for item in with_rollover.debts) == 12_000


def test_avalanche_and_snowball_report_objective_differences_without_mutation():
    debts = (
        StrategyDebt("high-rate", 10_000, 2_400, 500),
        StrategyDebt("small", 3_000, 0, 500),
    )
    avalanche = project_debt_strategy(
        debts, date(2026, 1, 15), strategy="avalanche", rollover=True,
        extra_payment_minor=500,
    )
    snowball = project_debt_strategy(
        debts, date(2026, 1, 15), strategy="snowball", rollover=True,
        extra_payment_minor=500,
    )

    assert avalanche.status == snowball.status == "paid_off"
    assert (avalanche.payment_count, avalanche.projected_interest_minor, avalanche.projected_total_paid_minor) == (10, 1_179, 14_179)
    assert (snowball.payment_count, snowball.projected_interest_minor, snowball.projected_total_paid_minor) == (10, 1_280, 14_280)
    assert avalanche.projected_interest_minor < snowball.projected_interest_minor
    assert avalanche.projected_total_paid_minor < snowball.projected_total_paid_minor
    assert debts[0].principal_minor == 10_000 and debts[1].principal_minor == 3_000


def test_custom_strategy_requires_complete_order_and_detects_non_amortizing():
    debts = [
        StrategyDebt("first", 10_000, 1_200, 50),
        StrategyDebt("second", 5_000, 0, 0),
    ]
    with pytest.raises(ValueError, match="every debt exactly once"):
        project_debt_strategy(
            debts, date(2026, 1, 1), strategy="custom", rollover=True,
            custom_order=["first"],
        )

    result = project_debt_strategy(
        debts, date(2026, 1, 1), strategy="custom", rollover=False,
        custom_order=["second", "first"],
    )
    assert result.status == "non_amortizing"
    assert result.debt_free_date is None
    assert result.payment_count == 1
