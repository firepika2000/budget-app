"""Add delegated budget boundaries and category rules."""

from alembic import op
import sqlalchemy as sa


revision = "0012_delegated_policies"
down_revision = "0011_credit_attribution"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "delegated_budget_policies",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pool_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("authority_minor", sa.BigInteger(), nullable=False),
        sa.Column("allow_category_creation", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("allow_reallocation", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("budget_id", "user_id"),
        sa.UniqueConstraint("pool_category_id"),
        sa.CheckConstraint("authority_minor >= 0", name="ck_delegated_authority_nonnegative"),
    )
    op.create_index("ix_delegated_budget_policies_budget_id", "delegated_budget_policies", ["budget_id"])
    op.create_index("ix_delegated_budget_policies_user_id", "delegated_budget_policies", ["user_id"])
    op.create_table(
        "delegated_category_rules",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("policy_id", sa.String(36), sa.ForeignKey("delegated_budget_policies.id", ondelete="CASCADE"), nullable=False),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="CASCADE"), nullable=False),
        sa.Column("rule_kind", sa.String(30), nullable=False),
        sa.Column("minimum_minor", sa.BigInteger(), nullable=True),
        sa.Column("maximum_minor", sa.BigInteger(), nullable=True),
        sa.UniqueConstraint("policy_id", "category_id"),
        sa.CheckConstraint("minimum_minor IS NULL OR minimum_minor >= 0", name="ck_delegated_rule_minimum"),
        sa.CheckConstraint("maximum_minor IS NULL OR maximum_minor >= 0", name="ck_delegated_rule_maximum"),
        sa.CheckConstraint("rule_kind IN ('hard_limit', 'soft_target', 'approval_gated')", name="ck_delegated_rule_kind"),
    )
    op.create_index("ix_delegated_category_rules_policy_id", "delegated_category_rules", ["policy_id"])
    op.create_index("ix_delegated_category_rules_category_id", "delegated_category_rules", ["category_id"])


def downgrade() -> None:
    op.drop_table("delegated_category_rules")
    op.drop_table("delegated_budget_policies")
