from datetime import date

import pytest
from fastapi import HTTPException

from app.import_review import load_match_observations
from app.models import Payee, PayeeAlias, User
from .conftest import auth
from .test_advanced_ledger import record, add_category
from .test_budgeting_api import create_budget, create_budget_structure, add_member


def test_import_observations_scope_before_matching(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    hidden = add_category(client, owner_token, budget["id"], "Private", "Private")
    shared = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    with session_factory() as db:
        shared_payee = db.get(Payee, shared["payee_id"])
        db.add(PayeeAlias(payee_id=shared_payee.id, display_name="Visible owner alias",
                          name_key="visible owner alias", created_by_user_id=shared_payee.created_by_user_id))
        db.commit()
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=hidden["id"], amount_minor=-100, payee_name="Secret")
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=100, payee_name="Salary")
    record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=-100, splits=[{"category_id": category["id"], "amount_minor": -50}, {"category_id": hidden["id"], "amount_minor": -50}])
    add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member_id = db.query(User).filter_by(email="contribute@example.com").one().id
    response = client.put(f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token), json={"capabilities": ["view_transactions", "create_transaction"], "restrict_accounts": True, "account_ids": [account["id"]], "restrict_categories": True, "category_ids": [category["id"]]})
    assert response.status_code == 200, response.text
    arguments = dict(budget_id=budget["id"], account_id=account["id"], start_date=date(2026, 9, 1), end_date=date(2026, 9, 30))
    with session_factory() as db:
        owner = db.query(User).filter_by(email="owner@example.com").one()
        owner_rows = load_match_observations(db, user=owner, **arguments)
        owner_shared = next(row for row in owner_rows if row.transaction_id == shared["id"])
        assert owner_shared.payee_aliases == ("Visible owner alias",)
        member = db.get(User, member_id)
        rows = load_match_observations(db, user=member, **arguments)
        assert [row.transaction_id for row in rows] == [shared["id"]]
        assert rows[0].payee_aliases == ()
        assert load_match_observations(db, user=member, **arguments, amounts={-100}) == rows
        assert load_match_observations(db, user=member, **arguments, amounts=set()) == []
        assert load_match_observations(db, user=member, **{**arguments, "end_date": date(2026, 9, 1)}) == []
        with pytest.raises(HTTPException) as error:
            load_match_observations(db, user=member, **{**arguments, "account_id": "missing"})
        assert error.value.status_code == 404
