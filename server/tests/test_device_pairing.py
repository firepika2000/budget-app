from datetime import datetime, timedelta, timezone
from hashlib import sha256

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.main import create_app
from app.models import PairingCode, RefreshSession


def secure_client(session_factory, tmp_path):
    settings = Settings(
        database_url="sqlite://",
        jwt_secret="pairing-test-secret-that-is-longer-than-32-characters",
        attachment_storage_path=str(tmp_path / "attachments"),
        pairing_public_url="https://budget.example.test",
    )
    app = create_app(settings)
    app.state.session_factory = session_factory
    return TestClient(app, base_url="https://testserver")


def bootstrap(client: TestClient) -> dict:
    response = client.post("/api/v1/auth/bootstrap", json={
        "email": "owner@example.com",
        "password": "correct horse battery staple",
        "display_name": "Owner",
        "household_name": "Home",
    })
    assert response.status_code == 201, response.text
    return response.json()


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_pairing_code_is_hashed_one_time_and_issues_revocable_labeled_session(
    session_factory, tmp_path
):
    with secure_client(session_factory, tmp_path) as client:
        owner = bootstrap(client)
        created = client.post("/api/v1/auth/pairing-code", headers=auth(owner["access_token"]))
        assert created.status_code == 201, created.text
        pairing = created.json()
        assert pairing["server_url"] == "https://budget.example.test"
        assert len(pairing["code"]) >= 40
        with session_factory() as db:
            stored = db.scalar(select(PairingCode))
            assert stored.token_hash == sha256(pairing["code"].encode()).hexdigest()
            assert pairing["code"] not in stored.token_hash

        redeemed = client.post("/api/v1/auth/pair", json={
            "code": pairing["code"], "device_name": "Rey's iPhone",
        })
        assert redeemed.status_code == 200, redeemed.text
        paired = redeemed.json()
        replay = client.post("/api/v1/auth/pair", json={
            "code": pairing["code"], "device_name": "Replay",
        })
        assert replay.status_code == 401

        sessions = client.get("/api/v1/auth/sessions", headers=auth(owner["access_token"]))
        assert sessions.status_code == 200
        paired_session = next(item for item in sessions.json() if item["device_name"] == "Rey's iPhone")
        rotated = client.post(
            "/api/v1/auth/refresh", json={"refresh_token": paired["refresh_token"]}
        )
        assert rotated.status_code == 200, rotated.text
        sessions = client.get("/api/v1/auth/sessions", headers=auth(owner["access_token"]))
        labeled_sessions = [
            item for item in sessions.json() if item["device_name"] == "Rey's iPhone"
        ]
        assert len(labeled_sessions) == 1
        assert labeled_sessions[0]["id"] != paired_session["id"]
        revoked = client.delete(
            f"/api/v1/auth/sessions/{labeled_sessions[0]['id']}",
            headers=auth(owner["access_token"]),
        )
        assert revoked.status_code == 204
        rejected = client.post(
            "/api/v1/auth/refresh", json={"refresh_token": rotated.json()["refresh_token"]}
        )
        assert rejected.status_code == 401


def test_regeneration_invalidates_prior_code_and_expired_code_cannot_pair(session_factory, tmp_path):
    with secure_client(session_factory, tmp_path) as client:
        owner = bootstrap(client)
        first = client.post("/api/v1/auth/pairing-code", headers=auth(owner["access_token"])).json()
        second = client.post("/api/v1/auth/pairing-code", headers=auth(owner["access_token"])).json()
        assert client.post("/api/v1/auth/pair", json={
            "code": first["code"], "device_name": "Old QR",
        }).status_code == 401
        with session_factory() as db:
            current = db.scalar(select(PairingCode).where(
                PairingCode.token_hash == sha256(second["code"].encode()).hexdigest()
            ))
            current.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
            db.commit()
        assert client.post("/api/v1/auth/pair", json={
            "code": second["code"], "device_name": "Expired QR",
        }).status_code == 401
        with session_factory() as db:
            assert db.scalar(select(RefreshSession).where(RefreshSession.device_name == "Expired QR")) is None


def test_pairing_fails_closed_without_https_or_canonical_public_url(session_factory, tmp_path):
    configured = Settings(
        database_url="sqlite://",
        jwt_secret="pairing-test-secret-that-is-longer-than-32-characters",
        attachment_storage_path=str(tmp_path / "attachments"),
        pairing_public_url="https://budget.example.test",
    )
    app = create_app(configured)
    app.state.session_factory = session_factory
    with TestClient(app, base_url="http://testserver") as insecure:
        owner = bootstrap(insecure)
        response = insecure.post("/api/v1/auth/pairing-code", headers=auth(owner["access_token"]))
        assert response.status_code == 400
        assert response.json()["detail"] == "Device pairing requires HTTPS"

    missing = Settings(
        database_url="sqlite://",
        jwt_secret="pairing-test-secret-that-is-longer-than-32-characters",
        attachment_storage_path=str(tmp_path / "other-attachments"),
    )
    second_app = create_app(missing)
    second_app.state.session_factory = session_factory
    with TestClient(second_app, base_url="https://testserver") as no_public_url:
        # Reuse the established owner/session authority; this endpoint must still fail before issuing a code.
        response = no_public_url.post(
            "/api/v1/auth/pairing-code", headers=auth(owner["access_token"])
        )
        assert response.status_code == 503
        assert response.json()["detail"] == "Secure device pairing is not configured"
