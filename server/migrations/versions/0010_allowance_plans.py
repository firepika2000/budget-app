"""Add recurring delegated allowance plans and auditable issuance records."""

from alembic import op
import sqlalchemy as sa


revision = "0010_allowance_plans"
down_revision = "0009_delegated_access"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "allowance_plans",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("delegated_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("source_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("next_issue_date", sa.Date(), nullable=False),
        sa.Column("recurrence_unit", sa.String(20), nullable=False),
        sa.Column("interval_count", sa.Integer(), nullable=False),
        sa.Column("rollover_policy", sa.String(30), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("amount_minor > 0", name="ck_allowance_plan_amount_positive"),
        sa.CheckConstraint("interval_count > 0", name="ck_allowance_plan_interval_positive"),
        sa.CheckConstraint("recurrence_unit IN ('week', 'month')", name="ck_allowance_plan_recurrence"),
        sa.CheckConstraint("rollover_policy IN ('rollover', 'use_it_or_lose_it')", name="ck_allowance_plan_rollover_policy"),
    )
    for column in ("budget_id", "delegated_user_id", "source_category_id", "next_issue_date"):
        op.create_index(f"ix_allowance_plans_{column}", "allowance_plans", [column])
    op.create_table(
        "allowance_splits",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("plan_id", sa.String(36), sa.ForeignKey("allowance_plans.id", ondelete="CASCADE"), nullable=False),
        sa.Column("destination_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.UniqueConstraint("plan_id", "destination_category_id"),
        sa.CheckConstraint("amount_minor > 0", name="ck_allowance_split_amount_positive"),
    )
    op.create_index("ix_allowance_splits_plan_id", "allowance_splits", ["plan_id"])
    op.create_index("ix_allowance_splits_destination_category_id", "allowance_splits", ["destination_category_id"])
    op.create_table(
        "allowance_issuances",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("plan_id", sa.String(36), sa.ForeignKey("allowance_plans.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("issued_on", sa.Date(), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("reclaimed_minor", sa.BigInteger(), nullable=False),
        sa.Column("allocation_operation_id", sa.String(36), sa.ForeignKey("allocation_operations.id", ondelete="RESTRICT"), nullable=False, unique=True),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("plan_id", "issued_on"),
        sa.CheckConstraint("amount_minor > 0", name="ck_allowance_issuance_amount_positive"),
        sa.CheckConstraint("reclaimed_minor >= 0", name="ck_allowance_issuance_reclaimed_nonnegative"),
    )
    for column in ("plan_id", "budget_id", "issued_on", "actor_user_id"):
        op.create_index(f"ix_allowance_issuances_{column}", "allowance_issuances", [column])


def downgrade() -> None:
    op.drop_table("allowance_issuances")
    op.drop_table("allowance_splits")
    op.drop_table("allowance_plans")
