import pytest

from app.config import Settings


def test_production_settings_parse_allowed_hosts(monkeypatch):
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", "postgresql+psycopg://budget:secret@database/budget")
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "a-real-random-secret-that-is-over-32-characters")
    monkeypatch.setenv("BUDGET_APP_ALLOWED_HOSTS", "budget.example.com, budget.internal")

    settings = Settings.from_environment()

    assert settings.allowed_hosts == ("budget.example.com", "budget.internal")


def test_example_jwt_secret_is_rejected(monkeypatch):
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", "postgresql+psycopg://budget:secret@database/budget")
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "replace-with-at-least-32-random-characters")

    with pytest.raises(RuntimeError, match="replaced"):
        Settings.from_environment()
