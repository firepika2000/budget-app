"""Enforce normalized category-name uniqueness within groups.

Legacy duplicate sets deliberately retain NULL keys so migration never deletes, merges, or
renames financial data. New writes and non-conflicting legacy rows use the constrained key.
"""

from collections import defaultdict

from alembic import op
import sqlalchemy as sa

revision = "0017_category_name_uniqueness"
down_revision = "0016_category_group_archival"
branch_labels = None
depends_on = None


def _normalize(value: str) -> str:
    return value.strip().casefold()


def upgrade() -> None:
    op.add_column("categories", sa.Column("name_key", sa.String(length=255), nullable=True))
    connection = op.get_bind()
    rows = connection.execute(sa.text("SELECT id, group_id, name FROM categories")).mappings().all()
    grouped: dict[tuple[str, str], list[str]] = defaultdict(list)
    for row in rows:
        grouped[(row["group_id"], _normalize(row["name"]))].append(row["id"])
    for (_, name_key), category_ids in grouped.items():
        if name_key and len(category_ids) == 1:
            connection.execute(
                sa.text("UPDATE categories SET name_key = :name_key WHERE id = :category_id"),
                {"name_key": name_key, "category_id": category_ids[0]},
            )
    op.create_index("uq_categories_group_name_key", "categories", ["group_id", "name_key"], unique=True)


def downgrade() -> None:
    op.drop_index("uq_categories_group_name_key", table_name="categories")
    op.drop_column("categories", "name_key")
