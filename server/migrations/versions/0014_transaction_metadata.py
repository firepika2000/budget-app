"""Add transaction flags, tags, and attachment metadata."""

from alembic import op
import sqlalchemy as sa


revision = "0014_transaction_metadata"
down_revision = "0013_transaction_history"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("transactions") as batch:
        batch.add_column(sa.Column("flag", sa.String(30), nullable=True))
        batch.add_column(sa.Column("tags", sa.JSON(), nullable=False, server_default="[]"))
        batch.add_column(sa.Column("attachment_metadata", sa.JSON(), nullable=False, server_default="[]"))


def downgrade() -> None:
    with op.batch_alter_table("transactions") as batch:
        batch.drop_column("attachment_metadata")
        batch.drop_column("tags")
        batch.drop_column("flag")
