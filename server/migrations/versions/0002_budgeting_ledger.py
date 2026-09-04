"""Create accounts, categories, assignments, and transactions."""

from alembic import op
import sqlalchemy as sa


revision = "0002_budgeting_ledger"
down_revision = "0001_identity_access"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "accounts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("account_type", sa.String(30), nullable=False),
        sa.Column("is_on_budget", sa.Boolean(), nullable=False),
        sa.Column("is_closed", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_accounts_budget_id", "accounts", ["budget_id"])
    op.create_table(
        "category_groups",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
    )
    op.create_index("ix_category_groups_budget_id", "category_groups", ["budget_id"])
    op.create_table(
        "categories",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("group_id", sa.String(36), sa.ForeignKey("category_groups.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("is_archived", sa.Boolean(), nullable=False),
    )
    op.create_index("ix_categories_budget_id", "categories", ["budget_id"])
    op.create_index("ix_categories_group_id", "categories", ["group_id"])
    op.create_table(
        "monthly_assignments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="CASCADE"), nullable=False),
        sa.Column("month", sa.Date(), nullable=False),
        sa.Column("assigned_minor", sa.BigInteger(), nullable=False),
        sa.UniqueConstraint("category_id", "month"),
    )
    op.create_index("ix_monthly_assignments_budget_id", "monthly_assignments", ["budget_id"])
    op.create_index("ix_monthly_assignments_category_id", "monthly_assignments", ["category_id"])
    op.create_table(
        "transactions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("occurred_on", sa.Date(), nullable=False),
        sa.Column("payee_name", sa.String(150), nullable=False),
        sa.Column("memo", sa.String(500), nullable=False),
        sa.Column("is_cleared", sa.Boolean(), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_transactions_budget_id", "transactions", ["budget_id"])
    op.create_index("ix_transactions_account_id", "transactions", ["account_id"])
    op.create_index("ix_transactions_category_id", "transactions", ["category_id"])
    op.create_index("ix_transactions_occurred_on", "transactions", ["occurred_on"])
    op.create_index("ix_transactions_created_by_user_id", "transactions", ["created_by_user_id"])


def downgrade() -> None:
    op.drop_table("transactions")
    op.drop_table("monthly_assignments")
    op.drop_table("categories")
    op.drop_table("category_groups")
    op.drop_table("accounts")
