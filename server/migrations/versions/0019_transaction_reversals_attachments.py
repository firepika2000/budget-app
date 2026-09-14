"""Add auditable transaction reversals and encrypted attachment metadata."""

from alembic import op
import sqlalchemy as sa

revision = "0019_txn_rev_attach"
down_revision = "0018_first_class_payees"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("transactions") as batch:
        batch.add_column(sa.Column("status", sa.String(20), nullable=False, server_default="posted"))
        batch.add_column(sa.Column("voided_at", sa.DateTime(timezone=True), nullable=True))
        batch.add_column(sa.Column("voided_by_user_id", sa.String(36), nullable=True))
        batch.add_column(sa.Column("void_reason", sa.String(500), nullable=True))
        batch.add_column(sa.Column("reversal_of_transaction_id", sa.String(36), nullable=True))
        batch.add_column(sa.Column("reversal_transaction_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_transactions_voided_by", "users", ["voided_by_user_id"], ["id"], ondelete="RESTRICT")
        batch.create_foreign_key("fk_transactions_reversal_of", "transactions", ["reversal_of_transaction_id"], ["id"], ondelete="RESTRICT")
        batch.create_foreign_key("fk_transactions_reversal", "transactions", ["reversal_transaction_id"], ["id"], ondelete="RESTRICT")
        batch.create_unique_constraint("uq_transactions_reversal_of", ["reversal_of_transaction_id"])
        batch.create_unique_constraint("uq_transactions_reversal", ["reversal_transaction_id"])
    op.create_index("ix_transactions_status", "transactions", ["status"])
    op.create_table(
        "transaction_attachments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("transaction_id", sa.String(36), sa.ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("filename", sa.String(255), nullable=False),
        sa.Column("content_type", sa.String(100), nullable=False),
        sa.Column("byte_count", sa.BigInteger(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("storage_key", sa.String(100), nullable=False, unique=True),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("detached_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("detached_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("purge_after", sa.DateTime(timezone=True), nullable=True),
    )
    for column in ("budget_id", "transaction_id", "created_by_user_id", "detached_at", "purge_after"):
        op.create_index(f"ix_transaction_attachments_{column}", "transaction_attachments", [column])


def downgrade() -> None:
    op.drop_table("transaction_attachments")
    op.drop_index("ix_transactions_status", table_name="transactions")
    with op.batch_alter_table("transactions") as batch:
        batch.drop_constraint("uq_transactions_reversal", type_="unique")
        batch.drop_constraint("uq_transactions_reversal_of", type_="unique")
        batch.drop_constraint("fk_transactions_reversal", type_="foreignkey")
        batch.drop_constraint("fk_transactions_reversal_of", type_="foreignkey")
        batch.drop_constraint("fk_transactions_voided_by", type_="foreignkey")
        for column in ("reversal_transaction_id", "reversal_of_transaction_id", "void_reason", "voided_by_user_id", "voided_at", "status"):
            batch.drop_column(column)
