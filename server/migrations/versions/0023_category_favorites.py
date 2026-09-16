"""Add user-scoped category favorites."""

import sqlalchemy as sa
from alembic import op


revision = "0023_category_favorites"
down_revision = "0022_report_query_indexes"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "category_favorites",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("budget_id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("category_id", sa.String(length=36), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["category_id"], ["categories.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "category_id", name="uq_category_favorite_user_category"),
    )
    op.create_index("ix_category_favorites_budget_id", "category_favorites", ["budget_id"])
    op.create_index("ix_category_favorites_user_id", "category_favorites", ["user_id"])
    op.create_index("ix_category_favorites_category_id", "category_favorites", ["category_id"])


def downgrade() -> None:
    op.drop_index("ix_category_favorites_category_id", table_name="category_favorites")
    op.drop_index("ix_category_favorites_user_id", table_name="category_favorites")
    op.drop_index("ix_category_favorites_budget_id", table_name="category_favorites")
    op.drop_table("category_favorites")
