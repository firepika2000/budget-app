"""Add split transactions, transfers, and reconciliation state."""

from alembic import op
import sqlalchemy as sa


revision = "0003_advanced_ledger"
down_revision = "0002_budgeting_ledger"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("reconciled_balance_minor", sa.BigInteger(), nullable=True))
    op.add_column("accounts", sa.Column("reconciled_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("transactions", sa.Column("transfer_id", sa.String(36), nullable=True))
    op.add_column(
        "transactions",
        sa.Column("is_reconciled", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_transactions_transfer_id", "transactions", ["transfer_id"])
    op.create_table(
        "transaction_splits",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "transaction_id",
            sa.String(36),
            sa.ForeignKey("transactions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "category_id",
            sa.String(36),
            sa.ForeignKey("categories.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("memo", sa.String(500), nullable=False),
    )
    op.create_index("ix_transaction_splits_transaction_id", "transaction_splits", ["transaction_id"])
    op.create_index("ix_transaction_splits_category_id", "transaction_splits", ["category_id"])


def downgrade() -> None:
    op.drop_table("transaction_splits")
    op.drop_index("ix_transactions_transfer_id", table_name="transactions")
    op.drop_column("transactions", "is_reconciled")
    op.drop_column("transactions", "transfer_id")
    op.drop_column("accounts", "reconciled_at")
    op.drop_column("accounts", "reconciled_balance_minor")
