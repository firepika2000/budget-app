"""Add persisted category-group archival."""

from alembic import op
import sqlalchemy as sa

revision = "0016_category_group_archival"
down_revision = "0015_scheduled_realization"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("category_groups", sa.Column("is_archived", sa.Boolean(), nullable=False, server_default=sa.false()))


def downgrade() -> None:
    op.drop_column("category_groups", "is_archived")
