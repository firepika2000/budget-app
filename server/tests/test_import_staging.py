from datetime import date

import pytest
from fastapi import HTTPException

from app.import_candidates import ImportCandidate
from app.import_staging import stage_candidates, get_staged_batch, cancel_staged_batch
from app.models import ImportBatch, Transaction, Payee, TransactionChange, User
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure, add_member


def test_staging_persistence_ownership_cancellation_and_money_neutrality(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    path = f"/api/v1/budgets/{budget['id']}/months/2026-09-01"
    before = client.get(path, headers=auth(owner_token)).json()
    row = ImportCandidate(2, date(2026, 9, 1), -123, "Private import merchant", "memo")
    with session_factory() as db:
        owner = db.query(User).one()
        owner_id = owner.id
        batch = stage_candidates(db, user=owner, budget_id=budget["id"], account_id=account["id"], currency_code="USD", candidates=[row], source_format="csv")
        batch_id = batch.id
        db.commit()
    add_member(session_factory, client, "manage", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="manage@example.com").one()
        with pytest.raises(HTTPException) as error:
            get_staged_batch(db, user=member, budget_id=budget["id"], batch_id=batch_id)
        assert error.value.status_code == 404
        owner = db.get(User, owner_id)
        loaded = get_staged_batch(db, user=owner, budget_id=budget["id"], batch_id=batch_id)
        assert loaded.candidates == [dict(source_row=2, occurred_on="2026-09-01", amount_minor=-123, payee=row.payee, memo="memo")]
        cancelled = cancel_staged_batch(db, user=owner, budget_id=budget["id"], batch_id=batch_id, expected_version=0)
        assert (cancelled.status, cancelled.version) == ("cancelled", 1)
        db.commit()
        with pytest.raises(HTTPException) as error:
            cancel_staged_batch(db, user=owner, budget_id=budget["id"], batch_id=batch_id, expected_version=0)
        assert error.value.status_code == 409
        assert all(db.query(model).count() == 0 for model in [Transaction, Payee, TransactionChange])
    assert client.get(path, headers=auth(owner_token)).json() == before


@pytest.mark.parametrize("rows,currency", [([], "USD"), ([ImportCandidate(2, date(2026, 1, 1), 2**63, "", "")], "USD"), ([ImportCandidate(2, date(2026, 1, 1), 1, "", "")], "EUR")])
def test_invalid_staging_does_not_persist(client, owner_token, session_factory, rows, currency):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        with pytest.raises(HTTPException) as error:
            stage_candidates(db, user=db.query(User).one(), budget_id=budget["id"], account_id=account["id"], currency_code=currency, candidates=rows, source_format="csv")
        assert error.value.status_code == 422
        assert db.query(ImportBatch).count() == 0


def test_staged_owner_loses_access_when_account_scope_revoked(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one()
        member_id = member.id
        batch = stage_candidates(db, user=member, budget_id=budget["id"], account_id=account["id"], currency_code="USD", candidates=[ImportCandidate(1, date(2026, 1, 1), -1, "Test", "")], source_format="csv")
        batch_id = batch.id
        db.commit()
    response = client.put(f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token), json={"capabilities": ["view_transactions", "create_transaction"], "restrict_accounts": True, "account_ids": [], "restrict_categories": False, "category_ids": []})
    assert response.status_code == 200
    with session_factory() as db:
        member = db.get(User, member_id)
        with pytest.raises(HTTPException) as error:
            get_staged_batch(db, user=member, budget_id=budget["id"], batch_id=batch_id)
        assert error.value.status_code == 404
        with pytest.raises(HTTPException):
            cancel_staged_batch(db, user=member, budget_id=budget["id"], batch_id=batch_id, expected_version=0)
        assert db.get(ImportBatch, batch_id).status == "review"
