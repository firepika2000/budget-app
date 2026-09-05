"""Preserve immutable transaction change history."""

from alembic import op
import sqlalchemy as sa


revision = "0013_transaction_history"
down_revision = "0012_delegated_policies"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "transaction_changes",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("transaction_id", sa.String(36), nullable=False),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("before_json", sa.Text(), nullable=True),
        sa.Column("after_json", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_transaction_changes_budget_id", "transaction_changes", ["budget_id"])
    op.create_index("ix_transaction_changes_transaction_id", "transaction_changes", ["transaction_id"])
    op.create_index("ix_transaction_changes_actor_user_id", "transaction_changes", ["actor_user_id"])
    op.create_index("ix_transaction_changes_action", "transaction_changes", ["action"])


def downgrade() -> None:
    op.drop_table("transaction_changes")
