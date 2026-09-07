from datetime import date

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


def freeze_today(monkeypatch, when: date, *modules) -> None:
    """Pin ``date.today()`` to ``when`` inside the given app modules.

    Forecast and planning-horizon logic anchor "now" with ``date.today()``. A
    test that asserts against fixed calendar dates must control that anchor,
    otherwise it silently starts passing or failing as the real wall clock
    advances past the fixture dates. This replaces only ``date.today``; genuine
    ``date(...)`` construction, comparison, and arithmetic keep working because
    the stand-in is a real ``date`` subclass. ``timedelta`` and other symbols are
    untouched.

    Pass the app modules whose module-global ``date`` should be frozen (each must
    use ``from datetime import date``)::

        from app import planning_routes
        freeze_today(monkeypatch, date(2026, 9, 1), planning_routes)
    """

    class _FrozenDate(date):
        @classmethod
        def today(cls) -> date:
            return when

    for module in modules:
        monkeypatch.setattr(module, "date", _FrozenDate)

