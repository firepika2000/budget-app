from __future__ import annotations

from .models import AccountDebtTerms


def debt_terms_snapshot(terms: AccountDebtTerms) -> dict:
    """Return only planning assumptions, preserving exact integer money and rates."""
    return {
        "terms_type": terms.terms_type,
        "annual_rate_basis_points": terms.annual_rate_basis_points,
        "rate_type": terms.rate_type,
        "payment_frequency": terms.payment_frequency,
        "scheduled_payment_minor": terms.scheduled_payment_minor,
        "minimum_payment_rule": terms.minimum_payment_rule,
        "minimum_payment_minor": terms.minimum_payment_minor,
        "minimum_payment_rate_basis_points": terms.minimum_payment_rate_basis_points,
        "due_day": terms.due_day,
        "statement_day": terms.statement_day,
        "original_principal_minor": terms.original_principal_minor,
        "original_term_months": terms.original_term_months,
        "remaining_term_months": terms.remaining_term_months,
        "promotional_rate_basis_points": terms.promotional_rate_basis_points,
        "promotional_ends_on": terms.promotional_ends_on.isoformat() if terms.promotional_ends_on else None,
    }
