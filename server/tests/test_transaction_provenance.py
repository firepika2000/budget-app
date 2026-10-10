from datetime import datetime, timezone

from sqlalchemy import event, insert
from sqlalchemy.orm import Session
from app.models import TransactionChange

from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import create_budget, create_budget_structure


def test_transaction_provenance_does_not_hydrate_large_edit_history(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200)
    when = datetime(2026, 9, 15, tzinfo=timezone.utc)
    with session_factory() as db:
        db.execute(insert(TransactionChange), [
            {"id": f"edit-{i:05d}", "budget_id": budget["id"], "transaction_id": transaction["id"],
             "actor_user_id": transaction["created_by_user_id"], "action": "updated", "created_at": when,
             "before_json": "{}", "after_json": "{}"} for i in range(10000)
        ])
        # A newer non-editor observation must not displace the latest edit.
        db.add(TransactionChange(id="not-an-edit", budget_id=budget["id"], transaction_id=transaction["id"],
                                 actor_user_id=transaction["created_by_user_id"], action="created",
                                 created_at=datetime(2026, 9, 16, tzinfo=timezone.utc)))
        db.commit()
    hydrated = []
    attribution_rows = []
    def on_execute(state):
        result = state.invoke_statement()
        if state.is_select and list(result.keys()) == ["transaction_id", "actor_user_id", "created_at"]:
            frozen = result.freeze()
            attribution_rows.append(len(frozen.data))
            return frozen()
        return result
    def on_load(session, instance):
        if isinstance(instance, TransactionChange):
            hydrated.append(instance.id)
    event.listen(Session, "loaded_as_persistent", on_load)
    event.listen(Session, "do_orm_execute", on_execute, retval=True)
    try:
        response = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token))
    finally:
        event.remove(Session, "loaded_as_persistent", on_load)
        event.remove(Session, "do_orm_execute", on_execute)
    assert response.status_code == 200, response.text
    row = next(item for item in response.json() if item["id"] == transaction["id"])
    assert row["last_modified_by_display_name"] == "Owner"
    assert row["last_modified_at"].startswith("2026-09-15")
    assert hydrated == [], "List attribution must not load historical snapshots or change entities"
    assert attribution_rows == [1], "Database must return only the latest scalar attribution per displayed transaction"


def test_transaction_list_exposes_authorized_creator_and_latest_editor(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(
        client, owner_token, budget["id"], account_id=account["id"],
        category_id=category["id"], amount_minor=-200, memo="Original",
    )
    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}",
        headers=auth(owner_token),
        json={
            "account_id": account["id"], "category_id": category["id"],
            "amount_minor": -200, "occurred_on": transaction["occurred_on"],
            "payee_name": transaction["payee_name"], "memo": "Corrected",
        },
    )
    assert updated.status_code == 200, updated.text

    response = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
    )
    assert response.status_code == 200, response.text
    row = next(item for item in response.json() if item["id"] == transaction["id"])
    assert row["created_by_display_name"] == "Owner"
    assert row["last_modified_by_user_id"] == row["created_by_user_id"]
    assert row["last_modified_by_display_name"] == "Owner"
    assert row["last_modified_at"] is not None
    assert row["memo"] == "Corrected"
