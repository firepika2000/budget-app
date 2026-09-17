import json
from datetime import date
from pathlib import Path

from app.debt_projection import StrategyDebt, project_debt_strategy


VECTORS = Path(__file__).parent / "debt_strategy_vectors" / "v1.json"


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
