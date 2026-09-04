from .conftest import auth


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


def test_wrong_password_and_missing_token_are_rejected(client, owner_token):
    assert client.post("/api/v1/auth/login", json={
        "email": "owner@example.com",
        "password": "wrong password",
    }).status_code == 401
    assert client.get("/api/v1/budgets").status_code == 401

