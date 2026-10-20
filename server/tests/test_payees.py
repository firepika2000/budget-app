from time import monotonic
from datetime import date
import pytest

from sqlalchemy import event
from sqlalchemy.orm import Session

from app.models import Budget, Category, Household, Membership, Payee, PayeeAlias, Transaction, TransactionChange, TransactionSplit, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def test_payee_category_suggestion_uses_last_three_eligible_purchases_without_ledger_loading(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    payee = client.post(f"{root}/payees", headers=auth(owner_token), json={"display_name": "Older merchant"}).json()
    with session_factory() as db:
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        group_id = db.get(Category, category["id"]).group_id
        other = Category(budget_id=budget["id"], group_id=group_id, name="Other")
        archived = Category(budget_id=budget["id"], group_id=group_id, name="Archived", is_archived=True)
        db.add_all([other, archived]); db.flush()
        def add(day, category_id, amount=-1, **kwargs):
            row = Transaction(budget_id=budget["id"], account_id=account["id"], category_id=category_id,
                payee_id=payee["id"], amount_minor=amount, occurred_on=date(2026, 9, day),
                payee_name="Older merchant", created_by_user_id=owner_id, **kwargs)
            db.add(row); db.flush(); return row
        add(1, other.id); add(2, category["id"]); add(3, category["id"])
        add(4, other.id, amount=1)
        add(5, other.id, status="voided")
        add(6, other.id, transfer_id="transfer")
        add(7, archived.id)
        split = add(8, None)
        db.add(TransactionSplit(transaction_id=split.id, category_id=other.id, amount_minor=-1))
        db.commit()
        before = [(row.id, row.amount_minor, row.category_id) for row in db.query(Transaction).order_by(Transaction.id)]
    loaded = []
    def observe(session, instance):
        if isinstance(instance, Transaction): loaded.append(instance.id)
    event.listen(Session, "loaded_as_persistent", observe)
    try:
        response = client.get(f"{root}/payees/{payee['id']}/category-suggestion", headers=auth(owner_token))
    finally:
        event.remove(Session, "loaded_as_persistent", observe)
    assert response.status_code == 200, response.text
    assert response.json() == {"category_id": category["id"]}
    assert loaded == []
    with session_factory() as db:
        assert [(row.id, row.amount_minor, row.category_id) for row in db.query(Transaction).order_by(Transaction.id)] == before


def test_payee_rename_and_merge_preserve_linked_schedule_decisions(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    source = client.post(f"{root}/payees", headers=auth(owner_token), json={"display_name": "Source"}).json()
    destination = client.post(f"{root}/payees", headers=auth(owner_token), json={"display_name": "Destination"}).json()
    schedule = client.post(f"{root}/scheduled-transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": source["id"],
        "name": "Source", "amount_minor": -123, "next_date": "2027-01-01",
        "recurrence_unit": "months", "interval_count": 1, "is_active": False,
    })
    assert schedule.status_code == 201, schedule.text
    schedule_id = schedule.json()["id"]
    def history():
        response = client.get(f"{root}/scheduled-transactions/history", headers=auth(owner_token))
        assert response.status_code == 200, response.text
        return [row for row in response.json() if row["schedule_id"] == schedule_id]
    assert len(history()) == 1
    for _ in range(2):
        response = client.put(f"{root}/payees/{source['id']}", headers=auth(owner_token), json={"display_name": "Renamed", "is_archived": False})
        assert response.status_code == 200, response.text
    assert len(history()) == 2, "No-op payee save must not duplicate a schedule decision"
    response = client.post(f"{root}/payees/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
    assert response.status_code == 200, response.text
    rows = history()
    assert len(rows) == 3
    updates = [row for row in rows if row["action"] == "updated"]
    assert {(row["before_snapshot"]["name"], row["after_snapshot"]["name"]) for row in updates} == {("Source", "Renamed"), ("Renamed", "Destination")}
    for row in updates:
        assert row["actor_user_id"]
        assert row["before_snapshot"]["amount_minor"] == row["after_snapshot"]["amount_minor"] == -123
        assert row["before_snapshot"]["is_active"] is row["after_snapshot"]["is_active"] is False
        assert not row["transaction_ids"]
    merged = next(row for row in updates if row["after_snapshot"]["name"] == "Destination")
    assert merged["before_snapshot"]["payee_id"] == source["id"]
    assert merged["after_snapshot"]["payee_id"] == destination["id"]
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 0


def test_payee_search_streams_exact_totals_without_loading_ledger_entities(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Long History"}).json()
    amounts = [-9_007_199_254_740_993, 9_007_199_254_740_992] + [-1] * 2000
    with session_factory() as db:
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        db.add_all([Transaction(budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
            payee_id=payee["id"], amount_minor=amount, occurred_on=date(2026, 9, 15),
            payee_name="Long History", created_by_user_id=owner_id) for amount in amounts])
        db.commit()

    loaded = []
    batches = []
    def observe(session, instance):
        if isinstance(instance, Transaction):
            loaded.append(instance.id)
    def observe_query(state):
        columns = getattr(state.statement, "selected_columns", None)
        if columns is not None and list(columns.keys()) == ["payee_id", "amount_minor"]:
            batches.append(state.execution_options.get("yield_per"))
    event.listen(Session, "loaded_as_persistent", observe)
    event.listen(Session, "do_orm_execute", observe_query)
    try:
        response = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=Long&limit=1", headers=auth(owner_token))
        legacy = client.get(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token))
    finally:
        event.remove(Session, "loaded_as_persistent", observe)
        event.remove(Session, "do_orm_execute", observe_query)
    assert response.status_code == 200, response.text
    item = response.json()["items"][0]
    assert item["transaction_count"] == len(amounts)
    assert item["net_amount_minor"] == sum(amounts) == -2001
    assert legacy.status_code == 200
    assert next(item for item in legacy.json() if item["id"] == payee["id"])["net_amount_minor"] == -2001
    assert loaded == [], "Bounded payee search must not materialize its entire contributing ledger"
    assert batches == [500, 500], "Scalar observations must be fetched in bounded batches"


def test_large_payee_rename_and_merge_flush_bounded_batches_without_losing_audits(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}/payees"
    source = client.post(root, headers=auth(owner_token), json={"display_name": "Source"}).json()
    destination = client.post(root, headers=auth(owner_token), json={"display_name": "Destination"}).json()
    with session_factory() as db:
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        db.add_all([Transaction(budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
            payee_id=source["id"], amount_minor=-index, occurred_on=date(2026, 9, 15),
            payee_name="Source", memo="Preserve", tags=["qa"], is_cleared=True, created_by_user_id=owner_id)
            for index in range(1201)])
        db.commit()
    batch_sizes = []
    ledger_entities = []
    def observe_flush(session, context, instances):
        batch_sizes.append(sum(isinstance(item, Transaction) for item in session.dirty))
    def observe_load(session, instance):
        if isinstance(instance, Transaction):
            ledger_entities.append(sum(isinstance(item, Transaction) for item in session.identity_map.values()))
    event.listen(Session, "before_flush", observe_flush)
    event.listen(Session, "loaded_as_persistent", observe_load)
    try:
        renamed = client.put(f"{root}/{source['id']}", headers=auth(owner_token), json={"display_name": "Renamed", "is_archived": False})
        assert renamed.status_code == 200, renamed.text
        merge_batches = 0
        def fail_second_batch(session, context, instances):
            nonlocal merge_batches
            if any(isinstance(item, TransactionChange) and item.action == "payee_merged" for item in session.new):
                merge_batches += 1
                if merge_batches == 2:
                    raise RuntimeError("injected later-batch failure")
        event.listen(Session, "before_flush", fail_second_batch)
        try:
            with pytest.raises(RuntimeError, match="later-batch failure"):
                client.post(f"{root}/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
        finally:
            event.remove(Session, "before_flush", fail_second_batch)
        with session_factory() as db:
            assert db.query(Transaction).filter_by(payee_id=source["id"]).count() == 1201
            assert db.query(Transaction).filter_by(payee_id=destination["id"]).count() == 0
            assert db.query(TransactionChange).filter_by(action="payee_merged").count() == 0
            assert db.get(Payee, source["id"]).merged_into_payee_id is None
        merged = client.post(f"{root}/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
        assert merged.status_code == 200, merged.text
    finally:
        event.remove(Session, "before_flush", observe_flush)
        event.remove(Session, "loaded_as_persistent", observe_load)
    assert max(batch_sizes) <= 500, "Do not retain every dirty ledger entity until commit"
    assert max(ledger_entities) <= 500, "Do not materialize the complete history before batching writes"
    assert merged.json()["transaction_count"] == 1201
    assert merged.json()["net_amount_minor"] == -sum(range(1201))
    with session_factory() as db:
        transactions = db.query(Transaction).filter_by(payee_id=destination["id"]).all()
        assert len(transactions) == 1201
        assert all(item.payee_name == "Destination" and item.memo == "Preserve" and item.tags == ["qa"] and item.is_cleared for item in transactions)
        ids = [item.id for item in transactions]
        for action in ["payee_renamed", "payee_merged"]:
            observations = db.query(TransactionChange).filter(TransactionChange.transaction_id.in_(ids), TransactionChange.action == action).all()
            assert len(observations) == 1201
            assert len({item.transaction_id for item in observations}) == 1201


def test_payee_identity_normalization_default_and_transaction_link(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "  Corner   Market  ", "default_category_id": category["id"],
    })
    assert created.status_code == 201
    payee = created.json()
    assert payee["display_name"] == "Corner Market"
    assert payee["default_category_id"] == category["id"]
    duplicate = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "corner market",
    })
    assert duplicate.status_code == 409

    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": payee["id"],
        "payee_name": "client cannot spoof this", "amount_minor": -1234, "occurred_on": "2026-09-04",
    })
    assert transaction.status_code == 201
    assert transaction.json()["payee_id"] == payee["id"]
    assert transaction.json()["payee_name"] == "Corner Market"
    listed = client.get(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token)).json()
    assert listed[0]["transaction_count"] == 1
    assert listed[0]["net_amount_minor"] == -1234


def test_free_text_transaction_resolves_or_creates_canonical_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "  Metadata   test ",
        "amount_minor": -200, "occurred_on": "2026-09-15",
    })
    assert created.status_code == 201, created.text
    transaction = created.json()
    assert transaction["payee_id"] is not None
    assert transaction["payee_name"] == "Metadata test"
    with session_factory() as db:
        payee = db.get(Payee, transaction["payee_id"])
        assert payee.display_name == "Metadata test"
        db.add(PayeeAlias(payee_id=payee.id, display_name="QA merchant", name_key="qa merchant", created_by_user_id=payee.created_by_user_id))
        db.commit()
    via_alias = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "qa MERCHANT",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    }).json()
    assert via_alias["payee_id"] == transaction["payee_id"]
    assert via_alias["payee_name"] == "Metadata test"


def test_payee_search_is_bounded_stable_alias_aware_and_paginated_at_household_scale(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    with session_factory() as db:
        household_id = db.get(Budget, budget["id"]).household_id
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        values = [Payee(household_id=household_id, display_name=f"Merchant {index:05d}", name_key=f"merchant {index:05d}", created_by_user_id=owner_id) for index in range(10_000)]
        db.add_all(values); db.flush()
        db.add(PayeeAlias(payee_id=values[-1].id, display_name="Needle Alias", name_key="needle alias", created_by_user_id=owner_id))
        db.commit()
        alias_payee_id = values[-1].id
    started = monotonic()
    first = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20", headers=auth(owner_token))
    assert monotonic() - started < 5.0
    assert first.status_code == 200, first.text
    assert len(first.json()["items"]) == 20
    assert first.json()["next_cursor"] is not None
    second = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20&cursor={first.json()['next_cursor']}", headers=auth(owner_token))
    assert second.status_code == 200
    assert not ({item["id"] for item in first.json()["items"]} & {item["id"] for item in second.json()["items"]})
    alias = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=needle&limit=20", headers=auth(owner_token)).json()
    assert [item["id"] for item in alias["items"]] == [alias_payee_id]
    assert alias["next_cursor"] is None
    invalid = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?cursor=not-a-cursor", headers=auth(owner_token))
    assert invalid.status_code == 422


def test_payee_alias_rename_archive_and_merge_preserve_transaction_audit(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    source = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart Store"}).json()
    destination = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart"}).json()
    alias = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token), json={"display_name": "WM SUPERCENTER"})
    assert alias.status_code == 201
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": source["id"],
        "amount_minor": -2500, "occurred_on": "2026-09-04",
    }).json()
    renamed = client.put(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}", headers=auth(owner_token), json={
        "display_name": "Walmart Store Renamed", "is_archived": False,
    })
    assert renamed.status_code == 200, renamed.text
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == source["id"]
        assert row.payee_name == "Walmart Store Renamed"
        rename = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_renamed").one()
        assert '"payee_name": "Walmart Store"' in rename.before_json
    merged = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
    assert merged.status_code == 200
    assert merged.json()["transaction_count"] == 1
    assert merged.json()["aliases"][0]["display_name"] == "WM SUPERCENTER"
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == destination["id"]
        assert row.payee_name == "Walmart"
        source_row = db.get(Payee, source["id"])
        assert source_row.is_archived is True
        assert source_row.merged_into_payee_id == destination["id"]
        change = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_merged").one()
        assert change.actor_user_id is not None

    # The merged source name becomes an alias, so future typed transactions
    # continue to resolve to the destination rather than recreating a payee.
    via_merged_name = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "walmart store renamed",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert via_merged_name.status_code == 201, via_merged_name.text
    assert via_merged_name.json()["payee_id"] == destination["id"]


def test_payee_history_is_immutable_attributed_bounded_and_suppresses_noops(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    payee = client.post(f"{root}/payees", headers=auth(owner_token), json={
        "display_name": "Corner Market", "default_category_id": category["id"],
    }).json()
    alias = client.post(f"{root}/payees/{payee['id']}/aliases", headers=auth(owner_token), json={
        "display_name": "CM #42",
    }).json()
    assert client.put(f"{root}/payees/{payee['id']}", headers=auth(owner_token), json={
        "display_name": "Corner Grocery", "is_archived": False,
        "default_category_id": category["id"],
    }).status_code == 200
    history_url = f"{root}/payees/{payee['id']}/history"
    history = client.get(history_url, headers=auth(owner_token))
    assert history.status_code == 200, history.text
    rows = history.json()
    assert {row["action"] for row in rows} == {"created", "preference_updated", "alias_added", "updated"}
    assert all(row["actor_user_id"] and row["actor_display_name"] for row in rows)
    alias_row = next(row for row in rows if row["action"] == "alias_added")
    assert alias_row["before_snapshot"]["aliases"] == []
    assert alias_row["after_snapshot"]["aliases"] == ["CM #42"]
    preference = next(row for row in rows if row["action"] == "preference_updated")
    assert preference["budget_id"] == budget["id"]
    assert preference["after_snapshot"] == {"default_category_id": category["id"]}

    # Saving the same state creates no replacement decision.
    count = len(rows)
    assert client.put(f"{root}/payees/{payee['id']}", headers=auth(owner_token), json={
        "display_name": "Corner Grocery", "is_archived": False,
        "default_category_id": category["id"],
    }).status_code == 200
    assert len(client.get(history_url, headers=auth(owner_token)).json()) == count
    assert len(client.get(f"{history_url}?limit=1&offset=1", headers=auth(owner_token)).json()) == 1
    assert client.get(f"{history_url}?limit=0", headers=auth(owner_token)).status_code == 422

    assert client.delete(f"{root}/payees/{payee['id']}/aliases/{alias['id']}", headers=auth(owner_token)).status_code == 204
    after_delete = client.get(history_url, headers=auth(owner_token)).json()
    assert after_delete[0]["action"] == "alias_removed"
    assert after_delete[0]["after_snapshot"]["aliases"] == []


def test_free_text_payee_creation_records_identity_history(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"],
        "payee_name": "New Merchant", "amount_minor": -100, "occurred_on": "2026-10-08",
    })
    assert created.status_code == 201, created.text
    payee_id = created.json()["payee_id"]
    rows = client.get(
        f"/api/v1/budgets/{budget['id']}/payees/{payee_id}/history", headers=auth(owner_token)
    ).json()
    assert len(rows) == 1
    assert rows[0]["action"] == "created"
    assert rows[0]["after_snapshot"]["display_name"] == "New Merchant"


def test_payee_and_alias_names_share_one_deterministic_namespace(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    first = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Corner Market",
    }).json()
    second = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Neighborhood Shop",
    }).json()

    canonical_collision = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{second['id']}/aliases",
        headers=auth(owner_token), json={"display_name": " corner   market "},
    )
    assert canonical_collision.status_code == 409

    alias = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{first['id']}/aliases",
        headers=auth(owner_token), json={"display_name": "CM Store"},
    )
    assert alias.status_code == 201
    payee_collision = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "cm store",
    })
    assert payee_collision.status_code == 409
    rename_collision = client.put(
        f"/api/v1/budgets/{budget['id']}/payees/{second['id']}", headers=auth(owner_token),
        json={"display_name": "CM STORE", "is_archived": False},
    )
    assert rename_collision.status_code == 409


def test_merge_deduplicates_aliases_and_rejects_inactive_endpoints(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    source = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Source Store"}).json()
    destination = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Destination Store"}).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Legacy Source"},
    ).status_code == 201

    merged = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token),
        json={"destination_payee_id": destination["id"]},
    )
    assert merged.status_code == 200, merged.text
    assert {item["display_name"] for item in merged.json()["aliases"]} == {"Legacy Source", "Source Store"}
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Must Fail"},
    ).status_code == 409
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token),
        json={"destination_payee_id": destination["id"]},
    ).status_code == 409


def test_scoped_payee_search_does_not_disclose_alias_metadata(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, private_category = create_budget_structure(client, owner_token, budget["id"])
    group = client.post(f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token), json={
        "name": "Shared", "sort_order": 20,
    }).json()
    shared_category = client.post(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token), json={
        "group_id": group["id"], "name": "Allowance", "sort_order": 10,
    }).json()
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Visible Store",
    }).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Private Household Alias"},
    ).status_code == 201
    assert client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": shared_category["id"], "payee_id": payee["id"],
        "amount_minor": -100, "occurred_on": "2026-09-15",
    }).status_code == 201

    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="payee-privacy@example.com", display_name="Scoped", password_hash=hash_password("password long enough"))
        db.add(member); db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="child")); db.commit()
        member_id = member.id
    token = create_access_token(member_id, client.app.state.settings)
    assert client.put(f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token), json={
        "user_id": member_id, "permission": "view",
    }).status_code == 200
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [shared_category["id"]],
    }).status_code == 200

    visible = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=visible", headers=auth(token))
    assert visible.status_code == 200
    assert [item["display_name"] for item in visible.json()["items"]] == ["Visible Store"]
    assert visible.json()["items"][0]["aliases"] == []
    by_alias = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=private", headers=auth(token))
    assert by_alias.status_code == 200
    assert by_alias.json() == {"items": [], "next_cursor": None}
    history = client.get(
        f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}/history", headers=auth(token)
    )
    assert history.status_code == 200
    assert all("aliases" not in row["after_snapshot"] for row in history.json())


def test_category_scoped_payees_exclude_uncategorized_income_and_private_defaults(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    group = client.post(f"{root}/category-groups", headers=auth(owner_token), json={"name": "Private"}).json()
    hidden = client.post(f"{root}/categories", headers=auth(owner_token), json={"group_id": group["id"], "name": "Private"}).json()
    visible_payee = client.post(f"{root}/payees", headers=auth(owner_token), json={
        "display_name": "Shared Merchant", "default_category_id": hidden["id"],
    }).json()
    private_payee = client.post(f"{root}/payees", headers=auth(owner_token), json={"display_name": "Private Salary"}).json()
    for payee, category_id, amount in [(visible_payee, category["id"], -100), (visible_payee, None, 50000), (private_payee, None, 90000)]:
        response = client.post(f"{root}/transactions", headers=auth(owner_token), json={
            "account_id": account["id"], "category_id": category_id, "payee_id": payee["id"],
            "amount_minor": amount, "occurred_on": "2026-09-15",
        })
        assert response.status_code == 201, response.text
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="category-payee-scope@example.com", display_name="Scoped", password_hash=hash_password("password long enough"))
        db.add(member); db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="adult")); db.commit()
        member_id = member.id
    token = create_access_token(member_id, client.app.state.settings)
    assert client.put(f"{root}/grants", headers=auth(owner_token), json={"user_id": member_id, "permission": "view"}).status_code == 200
    assert client.put(f"{root}/access/{member_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_transactions"], "restrict_accounts": False, "account_ids": [],
        "restrict_categories": True, "category_ids": [category["id"]],
    }).status_code == 200
    transactions = client.get(f"{root}/transactions/search", headers=auth(token))
    assert transactions.status_code == 200
    assert transactions.json()["total_count"] == 1
    for path in ["payees/search", "payees"]:
        response = client.get(f"{root}/{path}", headers=auth(token))
        assert response.status_code == 200
        rows = response.json()["items"] if path.endswith("search") else response.json()
        assert [row["id"] for row in rows] == [visible_payee["id"]]
        assert rows[0]["transaction_count"] == 1
        assert rows[0]["net_amount_minor"] == -100
        assert rows[0]["default_category_id"] is None
    assert client.get(f"{root}/payees/search?q=Private", headers=auth(token)).json() == {"items": [], "next_cursor": None}
    owner_rows = client.get(f"{root}/payees/search", headers=auth(owner_token)).json()["items"]
    owner_payee = next(row for row in owner_rows if row["id"] == visible_payee["id"])
    assert owner_payee["transaction_count"] == 2
    assert owner_payee["net_amount_minor"] == 49900
    assert owner_payee["default_category_id"] == hidden["id"]
    suggestion_path = f"{root}/payees/{visible_payee['id']}/category-suggestion"
    assert client.get(suggestion_path, headers=auth(token)).status_code == 403
    assert client.put(f"{root}/access/{member_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_transactions", "view_categories"], "restrict_accounts": False, "account_ids": [],
        "restrict_categories": True, "category_ids": [category["id"]],
    }).status_code == 200
    for _ in range(2):
        response = client.post(f"{root}/transactions", headers=auth(owner_token), json={
            "account_id": account["id"], "category_id": hidden["id"], "payee_id": visible_payee["id"],
            "amount_minor": -1, "occurred_on": "2026-09-15",
        })
        assert response.status_code == 201, response.text
    assert client.get(suggestion_path, headers=auth(owner_token)).json() == {"category_id": hidden["id"]}
    assert client.get(suggestion_path, headers=auth(token)).json() == {"category_id": None}
    assert client.get(f"{root}/payees/{private_payee['id']}/category-suggestion", headers=auth(token)).status_code == 404


def test_free_text_does_not_resurrect_archived_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Retired Merchant",
    }).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Old Storefront"},
    ).status_code == 201
    archived = client.put(f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}", headers=auth(owner_token), json={
        "display_name": "Retired Merchant", "is_archived": True,
    })
    assert archived.status_code == 200
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "retired merchant",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert transaction.status_code == 422
    assert transaction.json()["detail"] == "Invalid payee"
    via_archived_alias = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "old storefront",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert via_archived_alias.status_code == 422
    assert via_archived_alias.json()["detail"] == "Invalid payee"


def test_system_transaction_names_do_not_require_payee_identity(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={
        "name": "Checking", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 10000,
    }).json()
    transactions = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert transactions[0]["payee_name"] == "Starting Balance"
    assert transactions[0]["payee_id"] is None
    assert account["id"] == transactions[0]["account_id"]
