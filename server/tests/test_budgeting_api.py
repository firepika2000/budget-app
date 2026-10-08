from datetime import date
from pathlib import Path

from app.models import Budget, BudgetGrant, Household, Membership, User
from app.security import create_access_token, hash_password

from .conftest import auth


def create_budget(client, owner_token, session_factory, name="Family"):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    response = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id,
        "name": name,
        "currency_code": "USD",
        "starter_template": False,
    })
    assert response.status_code == 201
    return response.json()


def test_new_budget_installs_zero_money_starter_plan(client, owner_token, session_factory):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    response = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id,
        "name": "Fresh Budget",
        "currency_code": "USD",
    })
    assert response.status_code == 201
    budget_id = response.json()["id"]

    groups = client.get(f"/api/v1/budgets/{budget_id}/category-groups", headers=auth(owner_token))
    categories = client.get(f"/api/v1/budgets/{budget_id}/categories", headers=auth(owner_token))
    summary = client.get(f"/api/v1/budgets/{budget_id}/months/2026-10-01", headers=auth(owner_token))

    assert groups.status_code == categories.status_code == summary.status_code == 200
    assert [item["name"] for item in groups.json()] == [
        "Monthly Bills", "Everyday Spending", "True Expenses", "Goals",
    ]
    assert {item["name"] for item in categories.json()} == {
        "Housing", "Utilities", "Phone & Internet",
        "Groceries", "Transportation", "Dining & Fun",
        "Medical", "Home & Car Maintenance", "Annual Bills",
        "Emergency Fund", "Savings Goals",
    }
    assert summary.json()["ready_to_assign_minor"] == 0
    assert all(item["assigned_minor"] == 0 and item["activity_minor"] == 0 for item in summary.json()["categories"])


def test_budget_creation_can_explicitly_skip_starter_plan(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory, name="Imported Structure")
    groups = client.get(f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token))
    categories = client.get(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token))
    assert groups.status_code == categories.status_code == 200
    assert groups.json() == []
    assert categories.json() == []


def test_owner_can_confirm_and_completely_delete_one_populated_budget(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory, name="Delete Me")
    retained = create_budget(client, owner_token, session_factory, name="Keep Me")
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={"account_id": account["id"], "category_id": category["id"], "amount_minor": -1234,
              "occurred_on": "2026-10-01", "payee_name": "Delete Test"},
    )
    assert transaction.status_code == 201, transaction.text
    attachment = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions/{transaction.json()['id']}/attachments",
        headers={**auth(owner_token), "X-Attachment-Filename": "receipt.jpg",
                 "X-Attachment-Content-Type": "image/jpeg", "Content-Type": "application/octet-stream"},
        content=b"\xff\xd8\xfftest-receipt",
    )
    assert attachment.status_code == 201, attachment.text
    attachment_root = client.app.state.settings.attachment_storage_path
    assert list(Path(attachment_root).iterdir())

    viewer_token = add_member(session_factory, client, "view", budget["id"])
    assert client.request("DELETE", f"/api/v1/budgets/{budget['id']}", headers=auth(viewer_token),
                          json={"confirmation_name": "Delete Me"}).status_code == 404
    assert client.request("DELETE", f"/api/v1/budgets/{budget['id']}", headers=auth(owner_token),
                          json={"confirmation_name": "delete me"}).status_code == 422

    deleted = client.request("DELETE", f"/api/v1/budgets/{budget['id']}", headers=auth(owner_token),
                             json={"confirmation_name": "Delete Me"})
    assert deleted.status_code == 204, deleted.text
    listed = client.get("/api/v1/budgets", headers=auth(owner_token))
    assert [item["id"] for item in listed.json()] == [retained["id"]]
    assert list(Path(attachment_root).iterdir()) == []


def create_budget_structure(client, owner_token, budget_id):
    account = client.post(
        f"/api/v1/budgets/{budget_id}/accounts",
        headers=auth(owner_token),
        json={"name": "Checking", "account_type": "checking", "is_on_budget": True},
    )
    assert account.status_code == 201
    group = client.post(
        f"/api/v1/budgets/{budget_id}/category-groups",
        headers=auth(owner_token),
        json={"name": "Needs", "sort_order": 10},
    )
    assert group.status_code == 201
    category = client.post(
        f"/api/v1/budgets/{budget_id}/categories",
        headers=auth(owner_token),
        json={"group_id": group.json()["id"], "name": "Groceries", "sort_order": 10},
    )
    assert category.status_code == 201
    return account.json(), category.json()


def test_category_customization_round_trips_through_list_update_and_favorite(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory, name="Custom Plan")
    group = client.post(
        f"/api/v1/budgets/{budget['id']}/category-groups",
        headers=auth(owner_token), json={"name": "Needs", "sort_order": 10},
    ).json()
    created = client.post(
        f"/api/v1/budgets/{budget['id']}/categories",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": "Groceries", "icon_name": "cart.fill",
              "note": "Weekly staples", "sort_order": 10},
    )
    assert created.status_code == 201, created.text
    assert created.json()["icon_name"] == "cart.fill"
    assert created.json()["note"] == "Weekly staples"

    listed = client.get(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token))
    assert listed.status_code == 200, listed.text
    assert listed.json()[0]["icon_name"] == "cart.fill"
    assert listed.json()[0]["note"] == "Weekly staples"

    category_id = created.json()["id"]
    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category_id}",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": "Food", "icon_name": "fork.knife",
              "note": "Meals at home", "sort_order": 20, "is_archived": False},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["icon_name"] == "fork.knife"
    assert updated.json()["note"] == "Meals at home"

    favorite = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category_id}/favorite",
        headers=auth(owner_token), json={"sort_order": 2},
    )
    assert favorite.status_code == 200, favorite.text
    assert favorite.json()["icon_name"] == "fork.knife"
    assert favorite.json()["note"] == "Meals at home"

    invalid = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category_id}",
        headers=auth(owner_token),
        json={"group_id": group["id"], "name": "Food", "note": "x" * 501,
              "sort_order": 20, "is_archived": False},
    )
    assert invalid.status_code == 422


def test_category_and_group_reordering_is_atomic_and_authorized(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory, name="Ordered Plan")
    groups = [client.post(f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token), json={"name": name}).json() for name in ("First", "Second")]
    categories = [client.post(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token), json={"group_id": groups[0]["id"], "name": name}).json() for name in ("One", "Two", "Three")]

    reordered_groups = client.put(f"/api/v1/budgets/{budget['id']}/category-group-order", headers=auth(owner_token), json={"ordered_ids": [groups[1]["id"], groups[0]["id"]]})
    assert reordered_groups.status_code == 200, reordered_groups.text
    assert [row["id"] for row in reordered_groups.json()] == [groups[1]["id"], groups[0]["id"]]
    reordered_categories = client.put(f"/api/v1/budgets/{budget['id']}/category-order/{groups[0]['id']}", headers=auth(owner_token), json={"ordered_ids": [categories[2]["id"], categories[0]["id"], categories[1]["id"]]})
    assert reordered_categories.status_code == 200, reordered_categories.text
    assert [row["id"] for row in reordered_categories.json()] == [categories[2]["id"], categories[0]["id"], categories[1]["id"]]

    invalid = client.put(f"/api/v1/budgets/{budget['id']}/category-order/{groups[0]['id']}", headers=auth(owner_token), json={"ordered_ids": [categories[0]["id"]]})
    assert invalid.status_code == 422
    listed = client.get(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token)).json()
    assert [row["id"] for row in listed if row["group_id"] == groups[0]["id"]] == [categories[2]["id"], categories[0]["id"], categories[1]["id"]]

    viewer = add_member(session_factory, client, "view", budget["id"])
    denied = client.put(f"/api/v1/budgets/{budget['id']}/category-group-order", headers=auth(viewer), json={"ordered_ids": [groups[1]["id"], groups[0]["id"]]})
    assert denied.status_code == 403


def add_member(session_factory, client, permission, budget_id):
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(
            email=f"{permission}@example.com",
            display_name=permission.title(),
            password_hash=hash_password("member password long enough"),
        )
        db.add(member)
        db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="adult"))
        db.add(BudgetGrant(budget_id=budget_id, user_id=member.id, permission=permission))
        db.commit()
        return create_access_token(member.id, client.app.state.settings)


def test_owner_can_build_budget_and_record_exact_transaction(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])

    income = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": account["id"],
            "amount_minor": 100000,
            "occurred_on": "2026-09-01",
            "payee_name": "Opening funds",
            "is_cleared": True,
        },
    )
    assert income.status_code == 201

    assignment = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 45000},
    )
    assert assignment.status_code == 200
    assert assignment.json()["assigned_minor"] == 45000

    transaction = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": account["id"],
            "category_id": category["id"],
            "amount_minor": -12345,
            "occurred_on": str(date(2026, 9, 4)),
            "payee_name": "Grocery Store",
            "memo": "Weekly groceries",
            "is_cleared": True,
        },
    )
    assert transaction.status_code == 201
    assert transaction.json()["amount_minor"] == -12345
    listed = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
    )
    assert [item["payee_name"] for item in listed.json()] == ["Grocery Store", "Opening funds"]


def test_first_account_records_exact_starting_balance_and_makes_cash_available(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    created = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={
            "name": "Everyday Checking",
            "account_type": "checking",
            "is_on_budget": True,
            "starting_balance_minor": 123456,
        },
    )
    assert created.status_code == 201

    balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{created.json()['id']}/balance",
        headers=auth(owner_token),
    )
    assert balance.status_code == 200
    assert balance.json()["working_balance_minor"] == 123456
    assert balance.json()["cleared_balance_minor"] == 123456

    month = date.today().replace(day=1).isoformat()
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/{month}",
        headers=auth(owner_token),
    )
    assert summary.status_code == 200
    assert summary.json()["ready_to_assign_minor"] == 123456

    transactions = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(owner_token),
    ).json()
    assert len(transactions) == 1
    assert transactions[0]["amount_minor"] == 123456
    assert transactions[0]["payee_name"] == "Starting Balance"
    assert transactions[0]["category_id"] is None
    assert transactions[0]["is_cleared"] is True


def test_starting_balance_is_capability_gated_and_tracking_money_stays_out_of_rta(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    contributor_token = add_member(session_factory, client, "contribute", budget["id"])
    denied = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(contributor_token),
        json={"name": "Hidden", "account_type": "checking", "starting_balance_minor": 99999},
    )
    assert denied.status_code == 403

    tracking = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={
            "name": "Retirement",
            "account_type": "tracking",
            "is_on_budget": False,
            "starting_balance_minor": 9876543,
        },
    )
    assert tracking.status_code == 201
    month = date.today().replace(day=1).isoformat()
    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/{month}", headers=auth(owner_token)
    )
    assert summary.status_code == 200
    assert summary.json()["ready_to_assign_minor"] == 0


def test_contributor_can_transact_but_cannot_change_plan(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    contributor_token = add_member(session_factory, client, "contribute", budget["id"])

    transaction = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(contributor_token),
        json={
            "account_id": account["id"],
            "category_id": category["id"],
            "amount_minor": -500,
            "occurred_on": "2026-09-04",
        },
    )
    assert transaction.status_code == 201
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
        headers=auth(contributor_token),
        json={"month": "2026-09-01", "assigned_minor": 1000},
    ).status_code == 403


def test_account_metadata_edit_preserves_balance_and_ready_to_assign(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    created = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Everyday", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 200000},
    )
    assert created.status_code == 201
    account_id = created.json()["id"]
    month = date.today().replace(day=1).isoformat()
    before_balance = client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account_id}/balance", headers=auth(owner_token)).json()
    before_rta = client.get(f"/api/v1/budgets/{budget['id']}/months/{month}", headers=auth(owner_token)).json()["ready_to_assign_minor"]

    updated = client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account_id}",
        headers=auth(owner_token),
        json={"name": "Emergency Savings", "account_type": "savings"},
    )
    assert updated.status_code == 200
    assert updated.json()["name"] == "Emergency Savings"
    assert updated.json()["account_type"] == "savings"
    assert updated.json()["is_on_budget"] is True

    listed = client.get(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token)).json()
    assert [(item["name"], item["account_type"]) for item in listed] == [("Emergency Savings", "savings")]
    assert client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account_id}/balance", headers=auth(owner_token)).json() == before_balance
    assert client.get(f"/api/v1/budgets/{budget['id']}/months/{month}", headers=auth(owner_token)).json()["ready_to_assign_minor"] == before_rta == 200000

    history_path = f"/api/v1/budgets/{budget['id']}/accounts/{account_id}/history"
    revisions = client.get(history_path, headers=auth(owner_token))
    assert revisions.status_code == 200, revisions.text
    rows = revisions.json()
    assert [item["action"] for item in rows] == ["updated", "created"]
    assert rows[0]["before_snapshot"]["name"] == "Everyday"
    assert rows[0]["after_snapshot"]["name"] == "Emergency Savings"
    assert rows[0]["actor_display_name"]
    assert "starting_balance_minor" not in rows[1]["after_snapshot"]

    # An exact retry is a true no-op: no duplicate decision and no financial mutation.
    noop = client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account_id}", headers=auth(owner_token),
        json={"name": "Emergency Savings", "account_type": "savings"},
    )
    assert noop.status_code == 200
    assert client.get(history_path, headers=auth(owner_token)).json() == rows
    assert client.get(f"{history_path}?limit=1&offset=1", headers=auth(owner_token)).json() == rows[1:]
    assert client.get(f"{history_path}?limit=101", headers=auth(owner_token)).status_code == 422


def test_close_and_reopen_account_preserves_financial_state_and_blocks_new_posting(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    posted = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
        json={"account_id": account["id"], "category_id": category["id"],
              "amount_minor": -1234, "occurred_on": date.today().isoformat()},
    )
    assert posted.status_code == 201, posted.text
    transaction = posted.json()
    before = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json()

    closed = client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}",
        headers=auth(owner_token),
        json={"name": account["name"], "account_type": account["account_type"], "is_closed": True},
    )
    assert closed.status_code == 200, closed.text
    assert closed.json()["is_closed"] is True
    rejected = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token),
        json={"account_id": account["id"], "category_id": category["id"],
              "amount_minor": -100, "occurred_on": date.today().isoformat()},
    )
    assert rejected.status_code == 422
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json() == before

    reopened = client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}",
        headers=auth(owner_token),
        json={"name": account["name"], "account_type": account["account_type"], "is_closed": False},
    )
    assert reopened.status_code == 200, reopened.text
    assert reopened.json()["is_closed"] is False
    history = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert transaction["id"] in {item["id"] for item in history}


def test_account_metadata_rejects_financial_reclassification_and_unauthorized_edit(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    contributor_token = add_member(session_factory, client, "contribute", budget["id"])

    unsafe = client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}",
        headers=auth(owner_token),
        json={"name": "Card", "account_type": "credit"},
    )
    assert unsafe.status_code == 422
    assert "reinterpret financial history" in unsafe.json()["detail"]
    assert client.patch(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}",
        headers=auth(contributor_token),
        json={"name": "Renamed", "account_type": "checking"},
    ).status_code == 403


def test_account_creation_enforces_budget_treatment_type_families(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    for payload in (
        {"name": "Budget Loan", "account_type": "loan", "is_on_budget": True},
        {"name": "Tracked Cash", "account_type": "checking", "is_on_budget": False},
        {"name": "Tracked Card", "account_type": "credit", "is_on_budget": False},
    ):
        response = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json=payload)
        assert response.status_code == 422
    mortgage = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Mortgage", "account_type": "mortgage", "is_on_budget": False, "starting_balance_minor": -25000000},
    )
    assert mortgage.status_code == 201
    assert mortgage.json()["account_type"] == "mortgage"
    asset = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts",
        headers=auth(owner_token),
        json={"name": "Home value", "account_type": "asset", "is_on_budget": False, "starting_balance_minor": 40000000},
    )
    assert asset.status_code == 201
    assert asset.json()["account_type"] == "asset"


def test_viewer_cannot_add_transaction(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    viewer_token = add_member(session_factory, client, "view", budget["id"])

    response = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(viewer_token),
        json={
            "account_id": account["id"],
            "category_id": category["id"],
            "amount_minor": -500,
            "occurred_on": "2026-09-04",
        },
    )
    assert response.status_code == 403


def test_transaction_rejects_account_from_another_budget(
    client, owner_token, session_factory
):
    first = create_budget(client, owner_token, session_factory, "First")
    second = create_budget(client, owner_token, session_factory, "Second")
    foreign_account, _ = create_budget_structure(client, owner_token, second["id"])

    response = client.post(
        f"/api/v1/budgets/{first['id']}/transactions",
        headers=auth(owner_token),
        json={
            "account_id": foreign_account["id"],
            "amount_minor": -500,
            "occurred_on": "2026-09-04",
        },
    )
    assert response.status_code == 422
