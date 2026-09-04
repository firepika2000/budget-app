"""Add category targets and isolated scheduled planning records."""

from alembic import op
import sqlalchemy as sa


revision = "0007_targets_planning"
down_revision = "0006_allocation_ledger"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "category_targets",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="CASCADE"), nullable=False, unique=True),
        sa.Column("target_type", sa.String(30), nullable=False),
        sa.Column("target_amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("target_date", sa.Date(), nullable=True),
        sa.Column("recurrence_months", sa.Integer(), nullable=True),
        sa.Column("minimum_contribution_minor", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="50"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("target_amount_minor > 0", name="ck_category_target_amount_positive"),
        sa.CheckConstraint("minimum_contribution_minor >= 0", name="ck_category_target_minimum_nonnegative"),
        sa.CheckConstraint("priority >= 0 AND priority <= 100", name="ck_category_target_priority_range"),
        sa.CheckConstraint("recurrence_months IS NULL OR recurrence_months > 0", name="ck_category_target_recurrence_positive"),
    )
    op.create_index("ix_category_targets_budget_id", "category_targets", ["budget_id"])
    op.create_index("ix_category_targets_category_id", "category_targets", ["category_id"], unique=True)
    op.create_table(
        "scheduled_transactions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("destination_account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("name", sa.String(150), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("next_date", sa.Date(), nullable=False),
        sa.Column("recurrence_unit", sa.String(20), nullable=False),
        sa.Column("interval_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("memo", sa.String(500), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("interval_count > 0", name="ck_scheduled_interval_positive"),
    )
    op.create_index("ix_scheduled_transactions_budget_id", "scheduled_transactions", ["budget_id"])
    op.create_index("ix_scheduled_transactions_account_id", "scheduled_transactions", ["account_id"])
    op.create_index("ix_scheduled_transactions_destination_account_id", "scheduled_transactions", ["destination_account_id"])
    op.create_index("ix_scheduled_transactions_category_id", "scheduled_transactions", ["category_id"])
    op.create_index("ix_scheduled_transactions_next_date", "scheduled_transactions", ["next_date"])


def downgrade() -> None:
    op.drop_table("scheduled_transactions")
    op.drop_table("category_targets")
