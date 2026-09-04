import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import Settings
from app.database import Base
from app.main import create_app


@pytest.fixture
def session_factory():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False)
    engine.dispose()


@pytest.fixture
def client(session_factory):
    settings = Settings(
        database_url="sqlite://",
        jwt_secret="test-secret-that-is-longer-than-32-characters",
    )
    app = create_app(settings)
    app.state.session_factory = session_factory
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def owner_token(client):
    response = client.post("/api/v1/auth/bootstrap", json={
        "email": "owner@example.com",
        "password": "correct horse battery staple",
        "display_name": "Owner",
        "household_name": "Home",
    })
    assert response.status_code == 201
    return response.json()["access_token"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}

