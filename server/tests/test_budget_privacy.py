from app.models import Budget, BudgetGrant, Household, Membership, User
from app.security import create_access_token, hash_password

from .conftest import auth


def test_owner_can_create_and_list_budget(client, owner_token, session_factory):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    created = client.post("/api/v1/budgets", headers=auth(owner_token), json={
        "household_id": household_id,
        "name": "Family",
        "currency_code": "usd",
    })
    assert created.status_code == 201
    assert created.json()["currency_code"] == "USD"
    listed = client.get("/api/v1/budgets", headers=auth(owner_token))
    assert [item["name"] for item in listed.json()] == ["Family"]


def test_child_cannot_discover_sibling_budget_without_grant(
    client, owner_token, session_factory
):
    with session_factory() as db:
        household = db.query(Household).one()
        daughter = User(
            email="daughter@example.com",
            display_name="Daughter",
            password_hash=hash_password("daughter password long"),
        )
        son = User(
            email="son@example.com",
            display_name="Son",
            password_hash=hash_password("son password long enough"),
        )
        db.add_all([daughter, son])
        db.flush()
        db.add_all([
            Membership(household_id=household.id, user_id=daughter.id, role="child"),
            Membership(household_id=household.id, user_id=son.id, role="child"),
        ])
        daughter_budget = Budget(
            household_id=household.id,
            name="Daughter budget",
            currency_code="USD",
        )
        db.add(daughter_budget)
        db.flush()
        db.add(BudgetGrant(
            budget_id=daughter_budget.id,
            user_id=daughter.id,
            permission="manage",
        ))
        db.commit()
        son_token = create_access_token(son.id, client.app.state.settings)
        daughter_budget_id = daughter_budget.id

    assert client.get("/api/v1/budgets", headers=auth(son_token)).json() == []
    direct = client.get(
        f"/api/v1/budgets/{daughter_budget_id}",
        headers=auth(son_token),
    )
    assert direct.status_code == 404
    assert direct.json() == {"detail": "Budget not found"}


def test_inactive_member_cannot_use_existing_grant(client, owner_token, session_factory):
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(
            email="former@example.com",
            display_name="Former member",
            password_hash=hash_password("former password long enough"),
        )
        db.add(member)
        db.flush()
        db.add(Membership(
            household_id=household.id,
            user_id=member.id,
            role="adult",
            is_active=False,
        ))
        budget = Budget(household_id=household.id, name="Private", currency_code="USD")
        db.add(budget)
        db.flush()
        db.add(BudgetGrant(budget_id=budget.id, user_id=member.id, permission="manage"))
        db.commit()
        token = create_access_token(member.id, client.app.state.settings)

    assert client.get("/api/v1/budgets", headers=auth(token)).json() == []


def test_only_owner_can_grant_budget_access(client, owner_token, session_factory):
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(
            email="member@example.com",
            display_name="Member",
            password_hash=hash_password("member password long enough"),
        )
        db.add(member)
        db.flush()
        db.add(Membership(
            household_id=household.id,
            user_id=member.id,
            role="adult",
        ))
        budget = Budget(household_id=household.id, name="Shared", currency_code="USD")
        db.add(budget)
        db.commit()
        member_id = member.id
        budget_id = budget.id
        member_token = create_access_token(member.id, client.app.state.settings)

    owner_grant = client.put(
        f"/api/v1/budgets/{budget_id}/grants",
        headers=auth(owner_token),
        json={"user_id": member_id, "permission": "view"},
    )
    assert owner_grant.status_code == 200
    visible = client.get("/api/v1/budgets", headers=auth(member_token)).json()
    assert [item["id"] for item in visible] == [budget_id]

    forbidden_grant = client.put(
        f"/api/v1/budgets/{budget_id}/grants",
        headers=auth(member_token),
        json={"user_id": member_id, "permission": "manage"},
    )
    assert forbidden_grant.status_code == 404
