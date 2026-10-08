"""Persist per-user debt payoff forecast plans."""
import sqlalchemy as sa
from alembic import op

revision = "0038_debt_payoff_plan"
down_revision = "0037_reconciliation_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "debt_payoff_plans",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("budget_id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("strategy", sa.String(length=20), nullable=False),
        sa.Column("rollover", sa.Boolean(), nullable=False),
        sa.Column("extra_payment_minor", sa.BigInteger(), nullable=False),
        sa.Column("account_ids", sa.JSON(), nullable=False),
        sa.Column("custom_order", sa.JSON(), nullable=False),
        sa.Column("target_date", sa.Date(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("budget_id", "user_id", name="uq_debt_payoff_plan_budget_user"),
    )
    op.create_index("ix_debt_payoff_plans_budget_id", "debt_payoff_plans", ["budget_id"])
    op.create_index("ix_debt_payoff_plans_user_id", "debt_payoff_plans", ["user_id"])


def downgrade():
    op.drop_index("ix_debt_payoff_plans_user_id", table_name="debt_payoff_plans")
    op.drop_index("ix_debt_payoff_plans_budget_id", table_name="debt_payoff_plans")
    op.drop_table("debt_payoff_plans")
