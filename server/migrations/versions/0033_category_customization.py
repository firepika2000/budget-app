"""Persist optional category icons and notes."""
import sqlalchemy as sa
from alembic import op

revision = "0033_category_customization"
down_revision = "0032_offline_txn_idempotency"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("categories") as batch:
        batch.add_column(sa.Column("icon_name", sa.String(50), nullable=True))
        batch.add_column(sa.Column("note", sa.String(500), nullable=False, server_default=""))


def downgrade():
    with op.batch_alter_table("categories") as batch:
        batch.drop_column("note")
        batch.drop_column("icon_name")
