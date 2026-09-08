from datetime import date

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
    })
    assert response.status_code == 201
    return response.json()


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
