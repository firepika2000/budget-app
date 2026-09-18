import json
from datetime import date
from pathlib import Path

from app.debt_projection import ProjectionTerms, StrategyDebt, project_debt, project_debt_strategy


VECTORS = Path(__file__).parent / "debt_strategy_vectors" / "v1.json"


def test_shared_single_debt_calendar_rate_and_rounding_vectors_are_exact():
    payload = json.loads(VECTORS.with_name("single_v1.json").read_text())
    assert payload["format_version"] == 1
    for case in payload["cases"]:
        terms = dict(case["terms"])
        if terms.get("promotional_ends_on"):
            terms["promotional_ends_on"] = date.fromisoformat(terms["promotional_ends_on"])
        result = project_debt(case["principal_minor"], date.fromisoformat(case["first_payment_on"]), ProjectionTerms(**terms))
        assert {
            "status": result.status,
            "payoff_date": result.payoff_date.isoformat() if result.payoff_date else None,
            "payment_count": result.payment_count,
            "projected_interest_minor": result.projected_interest_minor,
            "projected_total_cost_minor": result.projected_total_cost_minor,
            "payment_dates": [point.payment_date.isoformat() for point in result.points],
            "interest_minor": [point.interest_minor for point in result.points],
            "payments_minor": [point.payment_minor for point in result.points],
            "ending_principal_minor": [point.ending_principal_minor for point in result.points],
        } == case["expected"], case["id"]


def test_shared_debt_strategy_golden_vectors_are_exact() -> None:
    payload = json.loads(VECTORS.read_text())
    assert payload["format_version"] == 1
    first_payment_on = date.fromisoformat(payload["first_payment_on"])

    for case in payload["cases"]:
        debts = [
            StrategyDebt(
                debt_id=item["id"],
                principal_minor=item["principal_minor"],
                annual_rate_basis_points=item["annual_rate_basis_points"],
                planned_payment_minor=item["planned_payment_minor"],
            )
            for item in case["debts"]
        ]
        result = project_debt_strategy(
            debts,
            first_payment_on,
            strategy=case["strategy"],
            rollover=case["rollover"],
            extra_payment_minor=case["extra_payment_minor"],
            custom_order=case.get("custom_order", ()),
        )
        expected = case["expected"]
        actual = {
            "status": result.status,
            "payoff_order": list(result.payoff_order),
            "debt_free_date": result.debt_free_date.isoformat() if result.debt_free_date else None,
            "payment_count": result.payment_count,
            "projected_interest_minor": result.projected_interest_minor,
            "projected_total_paid_minor": result.projected_total_paid_minor,
        }
        assert actual == expected, case["id"]
        assert all(
            isinstance(value, int) and not isinstance(value, bool)
            for key, value in actual.items()
            if key.endswith("_minor")
        ), case["id"]
