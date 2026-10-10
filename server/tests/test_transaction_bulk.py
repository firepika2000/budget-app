import pytest
from uuid import uuid4

from app.models import Transaction, TransactionChange, User

from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def _bulk(client, token, budget_id, transaction_ids, action, **values):
    return client.post(
        f"/api/v1/budgets/{budget_id}/transactions/bulk",
        headers=auth(token),
        json={"transaction_ids": transaction_ids, "action": action, **values},
    )


def test_stale_bulk_observation_rejects_entire_batch(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    rows = [record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100) for _ in range(2)]
    revisions = {row["id"]: row.get("revision", "v1:" + "0" * 64) for row in rows}
    assert _bulk(client, owner_token, budget["id"], [rows[0]["id"]], "set_flag", flag="orange").status_code == 200
    before = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    response = _bulk(client, owner_token, budget["id"], [row["id"] for row in rows], "set_cleared", cleared=True, expected_revisions=revisions)
    assert response.status_code == 409, response.text
    assert client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json() == before


def test_transaction_edit_rejects_stale_observation_without_overwriting_metadata(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, memo="Original")
    body = {key: row[key] for key in ["account_id", "category_id", "amount_minor", "occurred_on", "payee_name", "payee_id", "memo", "is_cleared", "flag", "tags"]}
    body.update(expected_revision=row.get("revision", "v1:" + "0" * 64), memo="Stale edit")
    assert _bulk(client, owner_token, budget["id"], [row["id"]], "set_flag", flag="orange").status_code == 200
    path = f"/api/v1/budgets/{budget['id']}/transactions"
    response = client.put(f"{path}/{row['id']}", headers=auth(owner_token), json=body)
    assert response.status_code == 409, response.text
    current = next(r for r in client.get(path, headers=auth(owner_token)).json() if r["id"] == row["id"])
    assert current["memo"] == "Original" and current["flag"] == "orange"
    body.update(expected_revision=current["revision"], flag="orange")
    accepted = client.put(f"{path}/{row['id']}", headers=auth(owner_token), json=body)
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["revision"] != current["revision"]


@pytest.mark.parametrize("replace_identity", [False, True])
def test_transaction_edit_preserves_creation_retry_identity(client, owner_token, session_factory, replace_identity):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    identity = str(uuid4())
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, client_operation_id=identity)
    body = {key: row[key] for key in ["account_id", "category_id", "amount_minor", "occurred_on", "payee_name", "memo", "is_cleared", "flag", "tags"]}
    body.update(memo="Edited", expected_revision=row["revision"])
    if replace_identity:
        body["client_operation_id"] = str(uuid4())
    response = client.put(f"/api/v1/budgets/{budget['id']}/transactions/{row['id']}", headers=auth(owner_token), json=body)
    assert response.status_code == 200, response.text
    with session_factory() as db:
        assert db.get(Transaction, row["id"]).client_operation_id == identity


@pytest.mark.parametrize("revisions", [{}, {"foreign": "v1:" + "0" * 64}, {"foreign": "invalid"}])
def test_bulk_revision_contract_requires_exact_selected_identity_set(client, owner_token, session_factory, revisions):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    response = _bulk(client, owner_token, budget["id"], [row["id"]], "set_cleared", cleared=True, expected_revisions=revisions)
    assert response.status_code == 422, response.text
    with session_factory() as db:
        assert db.get(Transaction, row["id"]).is_cleared is False


@pytest.mark.parametrize("action,values", [
    ("set_cleared", {"cleared": False}),
    ("set_flag", {"flag": " Orange "}),
    ("add_tags", {"tags": ["existing"]}),
    ("remove_tags", {"tags": ["absent"]}),
])
def test_bulk_noop_preserves_metadata_and_does_not_invent_edit_history(client, owner_token, session_factory, action, values):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"],
                         category_id=category["id"], amount_minor=-200, payee_name="Metadata test",
                         memo="keep exactly", flag="orange", tags=["existing"])
    with session_factory() as db:
        count = db.query(TransactionChange).filter_by(transaction_id=transaction["id"]).count()
    for _ in range(2):
        response = _bulk(client, owner_token, budget["id"], [transaction["id"]], action, **values)
        assert response.status_code == 200, response.text
        assert response.json() == [transaction]
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(transaction_id=transaction["id"]).count() == count


def test_bulk_tag_capacity_rejection_is_atomic_and_does_not_drop_requested_tags(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"],
                   category_id=category["id"], amount_minor=-100, tags=["existing"])
    full = record(client, owner_token, budget["id"], account_id=account["id"],
                  category_id=category["id"], amount_minor=-200, tags=[f"tag-{index}" for index in range(20)])
    before = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    with session_factory() as db:
        count = db.query(TransactionChange).filter_by(budget_id=budget["id"]).count()
    response = _bulk(client, owner_token, budget["id"], [first["id"], full["id"]], "add_tags", tags=["new"])
    assert response.status_code == 422, response.text
    assert "20 tags" in response.json()["detail"]
    assert client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json() == before
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(budget_id=budget["id"]).count() == count
    # An already-present tag fits even when the list is full, and is a true no-op.
    duplicate = _bulk(client, owner_token, budget["id"], [full["id"]], "add_tags", tags=["tag-0"])
    assert duplicate.status_code == 200, duplicate.text
    assert duplicate.json() == [full]


def test_bulk_tags_boundary_and_mixed_noop_only_audits_changed_rows(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, tags=["new"])
    second = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200, tags=[f"tag-{i}" for i in range(19)])
    response = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "add_tags", tags=[" NEW ", "new"])
    assert response.status_code == 200, response.text
    assert response.json()[0] == first
    assert response.json()[1]["tags"] == [*second["tags"], "new"]
    with session_factory() as db:
        changes = db.query(TransactionChange).filter_by(budget_id=budget["id"], action="bulk_updated").all()
        assert [change.transaction_id for change in changes] == [second["id"]]


def test_bulk_metadata_normalizes_and_audits_every_selected_transaction(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, tags=[" Existing "])
    second = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200)

    response = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "add_tags", tags=[" Review ", "review"])
    assert response.status_code == 200, response.text
    assert [row["tags"] for row in response.json()] == [["existing", "review"], ["review"]]
    response = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "set_flag", flag=" BLUE ")
    assert response.status_code == 200
    assert [row["flag"] for row in response.json()] == ["blue", "blue"]
    with session_factory() as db:
        assert db.query(TransactionChange).filter(TransactionChange.transaction_id.in_([first["id"], second["id"]]), TransactionChange.action == "bulk_updated").count() == 4


def test_bulk_rejection_is_atomic_for_missing_or_reconciled_member(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    first = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    second = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-200)

    missing = _bulk(client, owner_token, budget["id"], [first["id"], "missing"], "set_cleared", cleared=True)
    assert missing.status_code == 404
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in rows if row["id"] == first["id"])["is_cleared"] is False

    with session_factory() as db:
        db.get(Transaction, second["id"]).is_reconciled = True
        db.commit()
    denied = _bulk(client, owner_token, budget["id"], [first["id"], second["id"]], "set_flag", flag="red")
    assert denied.status_code == 409
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert all(row["flag"] is None for row in rows if row["id"] in {first["id"], second["id"]})


def test_bulk_rejects_system_linked_rows_without_partial_mutation(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    ordinary = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    opening_account = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
        json={"name": "Savings", "account_type": "savings", "is_on_budget": True, "starting_balance_minor": 5000},
    ).json()
    opening = next(row for row in client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json() if row["account_id"] == opening_account["id"])
    response = _bulk(client, owner_token, budget["id"], [ordinary["id"], opening["id"]], "set_cleared", cleared=True)
    assert response.status_code == 409
    rows = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in rows if row["id"] == ordinary["id"])["is_cleared"] is False


def test_single_transaction_clearing_persists_without_financial_mutation_or_permission_bypass(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transactions = [
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-4321),
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2222, tags=["existing"]),
        record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-3333, payee_name="Metadata Payee", memo="keep exactly", flag="purple"),
    ]
    def unchanged_metadata(row):
        return {key: value for key, value in row.items() if key not in {"is_cleared", "revision"}}

    for transaction in transactions:
        cleared = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=True)
        assert cleared.status_code == 200, cleared.text
        assert cleared.json()[0]["is_cleared"] is True
        assert unchanged_metadata(cleared.json()[0]) == unchanged_metadata(transaction)
        uncleared = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
        assert uncleared.status_code == 200, uncleared.text
        assert uncleared.json()[0]["is_cleared"] is False
        assert unchanged_metadata(uncleared.json()[0]) == unchanged_metadata(transaction)

    transaction = transactions[0]
    assert _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=True).status_code == 200
    persisted = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in persisted if row["id"] == transaction["id"])["is_cleared"] is True

    contributor_token = add_member(session_factory, client, "contribute", budget["id"])
    denied = _bulk(client, contributor_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
    assert denied.status_code == 403
    persisted = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert next(row for row in persisted if row["id"] == transaction["id"])["is_cleared"] is True

    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        row.is_reconciled = True
        db.commit()
    reconciled = _bulk(client, owner_token, budget["id"], [transaction["id"]], "set_cleared", cleared=False)
    assert reconciled.status_code == 409


def test_category_restriction_hides_uncategorized_transaction_from_every_mutation_surface(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    contributor_token = add_member(session_factory, client, "contribute", budget["id"])
    hidden = record(
        client, contributor_token, budget["id"], account_id=account["id"],
        amount_minor=5000, payee_name="Private uncategorized income",
    )
    with session_factory() as db:
        contributor_id = db.query(User.id).filter(User.email == "contribute@example.com").scalar()

    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{contributor_id}",
        headers=auth(owner_token),
        json={
            "capabilities": [
                "view_budget", "view_accounts", "view_categories", "view_transactions",
                "create_transaction", "edit_transaction", "delete_transaction", "manage_planning",
            ],
            "restrict_accounts": True,
            "account_ids": [account["id"]],
            "restrict_categories": True,
            "category_ids": [category["id"]],
        },
    )
    assert profile.status_code == 200, profile.text

    assert _search_ids(client, contributor_token, budget["id"]) == []
    attempts = [
        _bulk(client, contributor_token, budget["id"], [hidden["id"]], "set_flag", flag="red"),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/duplicate",
            headers=auth(contributor_token), json={"occurred_on": "2026-09-10"},
        ),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/void",
            headers=auth(contributor_token), json={"reason": "must remain hidden"},
        ),
        client.post(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/schedule",
            headers=auth(contributor_token),
            json={"next_date": "2026-10-01", "recurrence_unit": "months", "interval_count": 1},
        ),
        client.get(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}/attachments",
            headers=auth(contributor_token),
        ),
        client.put(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}",
            headers=auth(contributor_token),
            json={
                "account_id": account["id"], "category_id": category["id"],
                "amount_minor": -100, "occurred_on": "2026-09-10",
                "payee_name": "Attempted disclosure", "memo": "", "is_cleared": False,
                "splits": [], "tags": [],
            },
        ),
        client.delete(
            f"/api/v1/budgets/{budget['id']}/transactions/{hidden['id']}",
            headers=auth(contributor_token),
        ),
    ]
    assert [response.status_code for response in attempts] == [404] * len(attempts)

    with session_factory() as db:
        unchanged = db.get(Transaction, hidden["id"])
        assert unchanged is not None
        assert unchanged.payee_name == "Private uncategorized income"
        assert unchanged.flag is None
        assert unchanged.status == "posted"


def _search_ids(client, token, budget_id):
    response = client.get(
        f"/api/v1/budgets/{budget_id}/transactions/search", headers=auth(token),
    )
    assert response.status_code == 200, response.text
    return [row["id"] for row in response.json()["items"]]
