from datetime import date

import pytest
from fastapi import HTTPException

from app.budgeting_routes import create_transaction_in_session
from app.models import CreditCardReserveEvent, Payee, Transaction, TransactionChange, User
from app.schemas import TransactionCreate
from .test_budgeting_api import create_budget, create_budget_structure


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
