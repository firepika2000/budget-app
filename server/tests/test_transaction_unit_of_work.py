from datetime import date

import pytest
from fastapi import HTTPException

from app.budgeting_routes import create_transaction_in_session
from app.models import CreditCardReserveEvent, Payee, Transaction, TransactionChange, User
from app.schemas import TransactionCreate
from .test_budgeting_api import create_budget, create_budget_structure
from .conftest import auth
from .test_allocation_ledger import fund
from .test_credit_cards import create_credit_card, category_rows


def test_funded_card_failed_unit_restores_financial_observations(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=10000)
    response = client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment", headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 5000})
    assert response.status_code == 200
    before_summary = category_rows(client, owner_token, budget["id"])
    endpoint = f"/api/v1/budgets/{budget['id']}/transactions"
    before_transactions = client.get(endpoint, headers=auth(owner_token)).json()
    body = TransactionCreate(account_id=card["id"], category_id=category["id"], amount_minor=-1234, occurred_on=date(2026, 9, 1), payee_name="Rollback card merchant")
    with session_factory() as db:
        user = db.query(User).one()
        models = [Transaction, TransactionChange, Payee, CreditCardReserveEvent]
        counts = {model: db.query(model).count() for model in models}
        created = create_transaction_in_session(budget["id"], body, user=user, db=db)
        events = db.query(CreditCardReserveEvent).filter_by(source_transaction_id=created.id).all()
        assert events, "Exercise real reserve events, not an empty rollback assertion"
        assert db.query(CreditCardReserveEvent).count() > counts[CreditCardReserveEvent]
        with pytest.raises(HTTPException):
            create_transaction_in_session(budget["id"], body.model_copy(update={"category_id": "missing"}), user=user, db=db)
        db.rollback()
        assert {model: db.query(model).count() for model in models} == counts
    assert category_rows(client, owner_token, budget["id"]) == before_summary
    assert client.get(endpoint, headers=auth(owner_token)).json() == before_transactions


def test_canonical_creation_caller_can_roll_back_complete_unit(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    body = TransactionCreate(account_id=account["id"], category_id=category["id"], amount_minor=-123, occurred_on=date(2026, 1, 1), payee_name="Unit of work")
    original = body.model_dump()
    with session_factory() as db:
        user = db.query(User).one()
        before = {model: db.query(model).count() for model in [Transaction, TransactionChange, Payee, CreditCardReserveEvent]}
        created = create_transaction_in_session(budget["id"], body, user=user, db=db)
        assert created.amount_minor == -123
        assert created.payee_id is not None
        assert db.query(TransactionChange).count() == before[TransactionChange] + 1
        assert body.model_dump() == original
        with pytest.raises(HTTPException) as error:
            create_transaction_in_session(budget["id"], body.model_copy(update={"account_id": "missing"}), user=user, db=db)
        assert error.value.status_code == 422
        db.rollback()
        assert {model: db.query(model).count() for model in before} == before
    with session_factory() as db:
        user = db.query(User).one()
        first = create_transaction_in_session(budget["id"], body, user=user, db=db)
        second = create_transaction_in_session(budget["id"], body, user=user, db=db)
        assert first.id != second.id
        assert first.payee_id == second.payee_id
        db.commit()
    with session_factory() as db:
        assert db.query(Transaction).count() == before[Transaction] + 2
        assert db.query(TransactionChange).count() == before[TransactionChange] + 2
        assert db.query(Payee).count() == before[Payee] + 1
