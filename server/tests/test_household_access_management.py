from app.models import Household, Membership, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def add_member(session_factory, client, *, email: str, role: str = "adult"):
    with session_factory() as db:
        household = db.query(Household).one()
        user = User(
            email=email,
            display_name=email.split("@")[0].title(),
            password_hash=hash_password("password long enough"),
        )
        db.add(user)
        db.flush()
        db.add(Membership(household_id=household.id, user_id=user.id, role=role))
        db.commit()
        return user.id, create_access_token(user.id, client.app.state.settings)


def grant(client, owner_token, budget_id: str, user_id: str, permission: str):
    response = client.put(
        f"/api/v1/budgets/{budget_id}/grants",
        headers=auth(owner_token),
        json={"user_id": user_id, "permission": permission},
    )
    assert response.status_code == 200, response.text


def test_owner_can_inspect_legacy_and_persist_versioned_human_access_profile(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    member_id, member_token = add_member(
        session_factory, client, email="limited-access@example.com"
    )
    grant(client, owner_token, budget["id"], member_id, "view")
    url = f"/api/v1/budgets/{budget['id']}/access/{member_id}"
    with session_factory() as db:
        owner_id = db.query(Household).one().owner_user_id
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/access/{owner_id}", headers=auth(owner_token)
    ).status_code == 404
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/access/{owner_id}",
        headers=auth(owner_token),
        json={"capabilities": [], "expected_version": 0},
    ).status_code == 422

    legacy = client.get(url, headers=auth(owner_token))
    assert legacy.status_code == 200, legacy.text
    assert legacy.json()["grant_permission"] == "view"
    assert legacy.json()["is_custom"] is False
    assert legacy.json()["version"] == 0
    assert "create_transaction" not in legacy.json()["capabilities"]

    before_summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    before_balance = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json()
    payload = {
        "capabilities": [
            "view_budget", "view_accounts", "view_account_balances", "view_categories",
            "view_transactions", "view_reports", "create_transaction",
        ],
        "restrict_accounts": True,
        "account_ids": [account["id"]],
        "restrict_categories": True,
        "category_ids": [category["id"]],
        "expected_version": 0,
    }
    saved = client.put(url, headers=auth(owner_token), json=payload)
    assert saved.status_code == 200, saved.text
    body = saved.json()
    assert body["version"] > 0
    assert body["updated_by_user_id"]
    assert body["updated_by_display_name"]
    assert body["account_ids"] == [account["id"]]
    assert body["category_ids"] == [category["id"]]

    reloaded = client.get(url, headers=auth(owner_token))
    assert reloaded.status_code == 200
    assert reloaded.json() == body
    assert client.get(url, headers=auth(member_token)).status_code == 404
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(member_token)
    ).json()[0]["id"] == account["id"]
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json() == before_summary
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance",
        headers=auth(owner_token),
    ).json() == before_balance


def test_access_profile_rejects_stale_and_cross_household_edits(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    member_id, _ = add_member(session_factory, client, email="stale-access@example.com")
    outsider_id, outsider_token = add_member(
        session_factory, client, email="outsider-access@example.com"
    )
    grant(client, owner_token, budget["id"], member_id, "contribute")
    url = f"/api/v1/budgets/{budget['id']}/access/{member_id}"
    payload = {
        "capabilities": ["view_budget", "view_accounts", "view_categories"],
        "restrict_accounts": True,
        "account_ids": [account["id"]],
        "restrict_categories": True,
        "category_ids": [category["id"]],
        "expected_version": 0,
    }
    first = client.put(url, headers=auth(owner_token), json=payload)
    assert first.status_code == 200
    stale = client.put(url, headers=auth(owner_token), json=payload)
    assert stale.status_code == 409
    assert "Refresh" in stale.json()["detail"]
    assert client.get(url, headers=auth(outsider_token)).status_code == 404
    assert client.put(url, headers=auth(outsider_token), json=payload).status_code == 404
