from datetime import datetime, timedelta, timezone

from app.models import Household, Invitation, Membership, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_budgeting_api import create_budget


def invite(client, owner_token, household_id, email="child@example.com", role="child"):
    response = client.post(
        f"/api/v1/households/{household_id}/invitations",
        headers=auth(owner_token),
        json={"email": email, "role": role},
    )
    assert response.status_code == 201, response.text
    return response.json()


def accept(client, invitation_token, display_name="Child", password="child password long enough"):
    response = client.post("/api/v1/auth/accept-invitation", json={
        "invitation_token": invitation_token,
        "display_name": display_name,
        "password": password,
    })
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def test_owner_profile_contains_household_for_budget_creation(client, owner_token):
    response = client.get("/api/v1/me", headers=auth(owner_token))
    assert response.status_code == 200
    assert response.json()["email"] == "owner@example.com"
    assert response.json()["households"][0]["role"] == "owner"
    assert response.json()["households"][0]["is_active"] is True


def test_invitation_token_is_single_use_and_only_hash_is_stored(
    client, owner_token, session_factory
):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    invitation = invite(client, owner_token, household_id)
    raw_token = invitation["invitation_token"]
    with session_factory() as db:
        stored = db.query(Invitation).one()
        assert stored.token_hash != raw_token
        assert len(stored.token_hash) == 64

    member_token = accept(client, raw_token)
    assert client.get("/api/v1/me", headers=auth(member_token)).status_code == 200
    reused = client.post("/api/v1/auth/accept-invitation", json={
        "invitation_token": raw_token,
        "display_name": "Other",
        "password": "another password long enough",
    })
    assert reused.status_code == 400


def test_expired_invitation_is_rejected(client, owner_token, session_factory):
    with session_factory() as db:
        household_id = db.query(Household.id).scalar()
    invitation = invite(client, owner_token, household_id)
    with session_factory() as db:
        stored = db.query(Invitation).one()
        stored.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
        db.commit()
    response = client.post("/api/v1/auth/accept-invitation", json={
        "invitation_token": invitation["invitation_token"],
        "display_name": "Child",
        "password": "child password long enough",
    })
    assert response.status_code == 400
    assert response.json()["detail"] == "Invitation has expired"


def test_grant_revocation_and_member_deactivation_take_effect_immediately(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    household_id = budget["household_id"]
    member_token = accept(
        client,
        invite(client, owner_token, household_id)["invitation_token"],
    )
    members = client.get(
        f"/api/v1/households/{household_id}/members",
        headers=auth(owner_token),
    ).json()
    child = next(member for member in members if member["role"] == "child")
    assert client.get("/api/v1/budgets", headers=auth(member_token)).json() == []

    granted = client.put(
        f"/api/v1/budgets/{budget['id']}/grants",
        headers=auth(owner_token),
        json={"user_id": child["user_id"], "permission": "contribute"},
    )
    assert granted.status_code == 200
    assert len(client.get("/api/v1/budgets", headers=auth(member_token)).json()) == 1

    revoked = client.delete(
        f"/api/v1/budgets/{budget['id']}/grants/{child['user_id']}",
        headers=auth(owner_token),
    )
    assert revoked.status_code == 204
    assert client.get("/api/v1/budgets", headers=auth(member_token)).json() == []

    client.put(
        f"/api/v1/budgets/{budget['id']}/grants",
        headers=auth(owner_token),
        json={"user_id": child["user_id"], "permission": "view"},
    )
    deactivated = client.delete(
        f"/api/v1/households/{household_id}/members/{child['user_id']}",
        headers=auth(owner_token),
    )
    assert deactivated.status_code == 204
    assert client.get("/api/v1/budgets", headers=auth(member_token)).json() == []
    direct = client.get(
        f"/api/v1/budgets/{budget['id']}",
        headers=auth(member_token),
    )
    assert direct.status_code == 404


def test_non_owner_cannot_list_members_or_create_invitation(
    client, owner_token, session_factory
):
    with session_factory() as db:
        household = db.query(Household).one()
        adult = User(
            email="adult@example.com",
            display_name="Adult",
            password_hash=hash_password("adult password long enough"),
        )
        db.add(adult)
        db.flush()
        db.add(Membership(household_id=household.id, user_id=adult.id, role="adult"))
        db.commit()
        adult_token = create_access_token(adult.id, client.app.state.settings)
        household_id = household.id

    assert client.get(
        f"/api/v1/households/{household_id}/members",
        headers=auth(adult_token),
    ).status_code == 404
    assert client.post(
        f"/api/v1/households/{household_id}/invitations",
        headers=auth(adult_token),
        json={"email": "other@example.com", "role": "child"},
    ).status_code == 404
