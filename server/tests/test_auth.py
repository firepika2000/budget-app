from .conftest import auth
from app.models import RefreshSession


BOOTSTRAP_BODY = {
    "email": "owner@example.com",
    "password": "correct horse battery staple",
    "display_name": "Owner",
    "household_name": "Home",
}


def test_bootstrap_is_single_use(client):
    assert client.post("/api/v1/auth/bootstrap", json=BOOTSTRAP_BODY).status_code == 201
    second = client.post("/api/v1/auth/bootstrap", json={**BOOTSTRAP_BODY, "email": "other@example.com"})
    assert second.status_code == 409


def test_bootstrap_status_is_uninitialized_on_a_fresh_server(client):
    response = client.get("/api/v1/bootstrap/status")
    assert response.status_code == 200
    body = response.json()
    assert body["initialized"] is False
    assert body["authentication_required"] is True
    assert isinstance(body["api_version"], str) and body["api_version"]
    # Discovery must never require auth and must not leak household/user detail.
    assert set(body.keys()) == {"initialized", "authentication_required", "api_version"}


def test_bootstrap_status_becomes_initialized_after_first_owner_and_stays_claimed(client):
    assert client.post("/api/v1/auth/bootstrap", json=BOOTSTRAP_BODY).status_code == 201
    body = client.get("/api/v1/bootstrap/status").json()
    assert body["initialized"] is True
    # A second device cannot re-run first-owner bootstrap once initialized.
    assert client.post("/api/v1/auth/bootstrap", json={**BOOTSTRAP_BODY, "email": "second@example.com"}).status_code == 409
    # And the status response still leaks nothing about the owner/household.
    text = client.get("/api/v1/bootstrap/status").text
    assert "owner@example.com" not in text and "Home" not in text and "Owner" not in text


def test_bootstrap_status_does_not_require_authentication(client):
    # No Authorization header at all.
    assert client.get("/api/v1/bootstrap/status").status_code == 200


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


def test_repeated_login_failures_are_rate_limited(client, owner_token):
    body = {"email": "owner@example.com", "password": "wrong password"}
    for _ in range(10):
        assert client.post("/api/v1/auth/login", json=body).status_code == 401

    limited = client.post("/api/v1/auth/login", json=body)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) > 0


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
