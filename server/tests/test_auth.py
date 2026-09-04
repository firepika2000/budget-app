from .conftest import auth
from app.models import RefreshSession


def test_bootstrap_is_single_use(client):
    body = {
        "email": "owner@example.com",
        "password": "correct horse battery staple",
        "display_name": "Owner",
        "household_name": "Home",
    }
    assert client.post("/api/v1/auth/bootstrap", json=body).status_code == 201
    second = client.post("/api/v1/auth/bootstrap", json={**body, "email": "other@example.com"})
    assert second.status_code == 409


def test_login_returns_working_bearer_token(client, owner_token):
    response = client.post("/api/v1/auth/login", json={
        "email": "OWNER@example.com",
        "password": "correct horse battery staple",
    })
    assert response.status_code == 200
    budgets = client.get("/api/v1/budgets", headers=auth(response.json()["access_token"]))
    assert budgets.status_code == 200
    assert len(response.json()["refresh_token"]) >= 40


def test_wrong_password_and_missing_token_are_rejected(client, owner_token):
    assert client.post("/api/v1/auth/login", json={
        "email": "owner@example.com",
        "password": "wrong password",
    }).status_code == 401
    assert client.get("/api/v1/budgets").status_code == 401


def test_refresh_token_rotates_and_reuse_revokes_new_session(
    client, owner_token, session_factory
):
    login = client.post("/api/v1/auth/login", json={
        "email": "owner@example.com",
        "password": "correct horse battery staple",
    }).json()
    rotated = client.post("/api/v1/auth/refresh", json={
        "refresh_token": login["refresh_token"],
    })
    assert rotated.status_code == 200
    assert rotated.json()["refresh_token"] != login["refresh_token"]

    reused = client.post("/api/v1/auth/refresh", json={
        "refresh_token": login["refresh_token"],
    })
    assert reused.status_code == 401
    second_rejected = client.post("/api/v1/auth/refresh", json={
        "refresh_token": rotated.json()["refresh_token"],
    })
    assert second_rejected.status_code == 401
    with session_factory() as db:
        assert db.query(RefreshSession).filter(RefreshSession.revoked_at.is_(None)).count() == 0


def test_logout_revokes_refresh_token(client, owner_token):
    login = client.post("/api/v1/auth/login", json={
        "email": "owner@example.com",
        "password": "correct horse battery staple",
    }).json()
    response = client.post("/api/v1/auth/logout", json={
        "refresh_token": login["refresh_token"],
    })
    assert response.status_code == 204
    assert client.post("/api/v1/auth/refresh", json={
        "refresh_token": login["refresh_token"],
    }).status_code == 401
