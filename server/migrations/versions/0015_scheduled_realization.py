"""Add scheduled-transaction realization lineage and edit tracking."""

from alembic import op
import sqlalchemy as sa


revision = "0015_scheduled_realization"
down_revision = "0014_transaction_metadata"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("transactions", sa.Column("scheduled_transaction_id", sa.String(36), nullable=True))
    op.create_index(
        "ix_transactions_scheduled_transaction_id",
        "transactions",
        ["scheduled_transaction_id"],
    )
    op.add_column("scheduled_transactions", sa.Column("last_realized_on", sa.Date(), nullable=True))
    op.add_column(
        "scheduled_transactions",
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )


def downgrade() -> None:
    op.drop_column("scheduled_transactions", "updated_at")
    op.drop_column("scheduled_transactions", "last_realized_on")
    op.drop_index("ix_transactions_scheduled_transaction_id", table_name="transactions")
    op.drop_column("transactions", "scheduled_transaction_id")
