from datetime import date

from .conftest import auth
from .test_budgeting_api import create_budget
from .test_delegated_access import add_child


def create_account(client, token, budget_id, name, account_type, is_on_budget, balance=-250_000):
    response = client.post(
        f"/api/v1/budgets/{budget_id}/accounts",
        headers=auth(token),
        json={
            "name": name,
            "account_type": account_type,
            "is_on_budget": is_on_budget,
            "starting_balance_minor": balance,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_credit_card_terms_are_optional_exact_and_money_neutral(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    card = create_account(client, owner_token, budget["id"], "Card", "credit", True)
    path = f"/api/v1/budgets/{budget['id']}"
    before_balance = client.get(f"{path}/accounts/{card['id']}/balance", headers=auth(owner_token)).json()
    month = date.today().replace(day=1).isoformat()
    before_month = client.get(f"{path}/months/{month}", headers=auth(owner_token)).json()

    incomplete = client.put(
        f"{path}/accounts/{card['id']}/debt-terms",
        headers=auth(owner_token),
        json={"terms_type": "credit_card", "annual_rate_basis_points": 1999},
    )
    assert incomplete.status_code == 200, incomplete.text
    assert incomplete.json()["projection_ready"] is False
    assert set(incomplete.json()["missing_projection_fields"]) == {
        "rate_type", "payment_frequency", "due_day", "minimum_payment_rule"
    }

    complete = client.put(
        f"{path}/accounts/{card['id']}/debt-terms",
        headers=auth(owner_token),
        json={
            "terms_type": "credit_card",
            "annual_rate_basis_points": 1999,
            "rate_type": "variable",
            "payment_frequency": "monthly",
            "minimum_payment_rule": "greater_of",
            "minimum_payment_minor": 3500,
            "minimum_payment_rate_basis_points": 200,
            "due_day": 18,
            "statement_day": 21,
            "promotional_rate_basis_points": 0,
            "promotional_ends_on": "2027-03-31",
        },
    )
    assert complete.status_code == 200, complete.text
    assert complete.json()["projection_ready"] is True
    assert complete.json()["annual_rate_basis_points"] == 1999
    assert client.get(
        f"{path}/accounts/{card['id']}/debt-terms", headers=auth(owner_token)
    ).json() == complete.json()
    assert client.get(f"{path}/accounts/{card['id']}/balance", headers=auth(owner_token)).json() == before_balance
    assert client.get(f"{path}/months/{month}", headers=auth(owner_token)).json() == before_month


def test_installment_terms_reject_credit_fields_and_non_debt_accounts(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    path = f"/api/v1/budgets/{budget['id']}"
    loan = create_account(client, owner_token, budget["id"], "Auto loan", "loan", False)
    checking = create_account(client, owner_token, budget["id"], "Checking", "checking", True, 0)

    wrong_shape = client.put(
        f"{path}/accounts/{loan['id']}/debt-terms",
        headers=auth(owner_token),
        json={
            "terms_type": "installment_loan",
            "annual_rate_basis_points": 625,
            "minimum_payment_minor": 41200,
        },
    )
    assert wrong_shape.status_code == 422

    terms = client.put(
        f"{path}/accounts/{loan['id']}/debt-terms",
        headers=auth(owner_token),
        json={
            "terms_type": "installment_loan",
            "annual_rate_basis_points": 625,
            "rate_type": "fixed",
            "payment_frequency": "monthly",
            "scheduled_payment_minor": 41200,
            "due_day": 1,
            "original_principal_minor": 2_200_000,
            "original_term_months": 60,
            "remaining_term_months": 43,
        },
    )
    assert terms.status_code == 200, terms.text
    assert terms.json()["projection_ready"] is True
    assert client.put(
        f"{path}/accounts/{checking['id']}/debt-terms",
        headers=auth(owner_token),
        json={"terms_type": "installment_loan"},
    ).status_code == 422


def test_debt_terms_follow_account_scope_and_export(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    path = f"/api/v1/budgets/{budget['id']}"
    visible = create_account(client, owner_token, budget["id"], "Visible card", "credit", True)
    hidden = create_account(client, owner_token, budget["id"], "Private card", "credit", True)
    for account in (visible, hidden):
        response = client.put(
            f"{path}/accounts/{account['id']}/debt-terms",
            headers=auth(owner_token),
            json={"terms_type": "credit_card", "annual_rate_basis_points": 2199},
        )
        assert response.status_code == 200

    child_id, child_token = add_child(session_factory, client)
    assert client.put(f"{path}/grants", headers=auth(owner_token), json={
        "user_id": child_id, "permission": "contribute",
    }).status_code == 200
    assert client.put(f"{path}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_account_balances"],
        "restrict_accounts": True,
        "account_ids": [visible["id"]],
        "restrict_categories": False,
        "category_ids": [],
    }).status_code == 200
    assert client.get(
        f"{path}/accounts/{visible['id']}/debt-terms", headers=auth(child_token)
    ).status_code == 200
    hidden_response = client.get(
        f"{path}/accounts/{hidden['id']}/debt-terms", headers=auth(child_token)
    )
    assert hidden_response.status_code == 404
    assert hidden["id"] not in hidden_response.text

    exported = client.get(f"{path}/export.json", headers=auth(owner_token))
    assert exported.status_code == 200
    assert {item["account_id"] for item in exported.json()["account_debt_terms"]} == {
        visible["id"], hidden["id"]
    }

    assert client.delete(
        f"{path}/accounts/{visible['id']}/debt-terms", headers=auth(owner_token)
    ).status_code == 204
    assert client.get(
        f"{path}/accounts/{visible['id']}/debt-terms", headers=auth(owner_token)
    ).json() is None
