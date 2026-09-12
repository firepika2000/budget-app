from pathlib import Path

from alembic import command
from alembic.config import Config
import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError


def test_legacy_duplicate_category_names_survive_and_new_keys_are_constrained(tmp_path, monkeypatch):
    database_path = tmp_path / "legacy-duplicates.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0016_category_group_archival")

    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(text("PRAGMA foreign_keys = OFF"))
        connection.execute(text(
            "INSERT INTO category_groups (id, budget_id, name, sort_order, is_archived) "
            "VALUES ('group-1', 'budget-1', 'Savings', 0, 0)"
        ))
        connection.execute(text(
            "INSERT INTO categories (id, budget_id, group_id, name, sort_order, is_archived) VALUES "
            "('cat-1', 'budget-1', 'group-1', 'Emergency Fund', 0, 0), "
            "('cat-2', 'budget-1', 'group-1', ' emergency fund ', 1, 0), "
            "('cat-3', 'budget-1', 'group-1', 'Vacation', 2, 0)"
        ))

    command.upgrade(config, "head")
    with engine.connect() as connection:
        rows = connection.execute(text(
            "SELECT id, name, name_key FROM categories ORDER BY id"
        )).mappings().all()
        assert [(row["id"], row["name"]) for row in rows] == [
            ("cat-1", "Emergency Fund"),
            ("cat-2", " emergency fund "),
            ("cat-3", "Vacation"),
        ]
        assert rows[0]["name_key"] is None
        assert rows[1]["name_key"] is None
        assert rows[2]["name_key"] == "vacation"
        indexes = connection.execute(text("PRAGMA index_list('categories')")).mappings().all()
        assert any(row["name"] == "uq_categories_group_name_key" and row["unique"] == 1 for row in indexes)
    with pytest.raises(IntegrityError):
        with engine.begin() as connection:
            connection.execute(text(
                "INSERT INTO categories (id, budget_id, group_id, name, name_key, sort_order, is_archived) "
                "VALUES ('cat-4', 'budget-1', 'group-1', 'VACATION', 'vacation', 3, 0)"
            ))
    engine.dispose()
