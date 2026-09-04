"""Add scoped capabilities, delegated categories, and auditable requests."""

from alembic import op
import sqlalchemy as sa


revision = "0009_delegated_access"
down_revision = "0008_credit_reserves"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "budget_access_profiles",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("restrict_accounts", sa.Boolean(), nullable=False),
        sa.Column("restrict_categories", sa.Boolean(), nullable=False),
        sa.Column("updated_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("budget_id", "user_id"),
    )
    op.create_index("ix_budget_access_profiles_budget_id", "budget_access_profiles", ["budget_id"])
    op.create_index("ix_budget_access_profiles_user_id", "budget_access_profiles", ["user_id"])
    op.create_table(
        "capability_grants",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("capability", sa.String(50), nullable=False),
        sa.UniqueConstraint("budget_id", "user_id", "capability"),
    )
    op.create_index("ix_capability_grants_budget_id", "capability_grants", ["budget_id"])
    op.create_index("ix_capability_grants_user_id", "capability_grants", ["user_id"])
    op.create_index("ix_capability_grants_capability", "capability_grants", ["capability"])
    op.create_table(
        "resource_grants",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("resource_type", sa.String(20), nullable=False),
        sa.Column("resource_id", sa.String(36), nullable=False),
        sa.UniqueConstraint("budget_id", "user_id", "resource_type", "resource_id"),
        sa.CheckConstraint("resource_type IN ('account', 'category')", name="ck_resource_grant_type"),
    )
    for column in ("budget_id", "user_id", "resource_type", "resource_id"):
        op.create_index(f"ix_resource_grants_{column}", "resource_grants", [column])

    with op.batch_alter_table("categories") as batch_op:
        batch_op.add_column(sa.Column("delegated_user_id", sa.String(36), nullable=True))
        batch_op.create_foreign_key(
            "fk_categories_delegated_user_id", "users", ["delegated_user_id"], ["id"], ondelete="RESTRICT"
        )
        batch_op.create_index("ix_categories_delegated_user_id", ["delegated_user_id"])

    op.create_table(
        "financial_requests",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("household_id", sa.String(36), sa.ForeignKey("households.id", ondelete="CASCADE"), nullable=False),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("requester_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("request_type", sa.String(40), nullable=False),
        sa.Column("destination_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("requested_amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("reason", sa.String(500), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("approved_amount_minor", sa.BigInteger(), nullable=True),
        sa.Column("source_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("allocation_operation_id", sa.String(36), sa.ForeignKey("allocation_operations.id", ondelete="RESTRICT"), nullable=True, unique=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("requested_amount_minor > 0", name="ck_financial_request_amount_positive"),
        sa.CheckConstraint("approved_amount_minor IS NULL OR approved_amount_minor >= 0", name="ck_financial_request_approved_nonnegative"),
        sa.CheckConstraint(
            "status IN ('pending', 'approved', 'partially_approved', 'rejected', "
            "'changes_requested', 'cancelled', 'expired')",
            name="ck_financial_request_status",
        ),
        sa.CheckConstraint(
            "(status IN ('approved', 'partially_approved') AND approved_amount_minor IS NOT NULL "
            "AND source_category_id IS NOT NULL AND allocation_operation_id IS NOT NULL) OR "
            "(status NOT IN ('approved', 'partially_approved') AND allocation_operation_id IS NULL)",
            name="ck_financial_request_approval_link",
        ),
    )
    for column in (
        "household_id", "budget_id", "requester_user_id", "destination_category_id",
        "status", "source_category_id",
    ):
        op.create_index(f"ix_financial_requests_{column}", "financial_requests", [column])
    op.create_table(
        "request_actions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("request_id", sa.String(36), sa.ForeignKey("financial_requests.id", ondelete="CASCADE"), nullable=False),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("action", sa.String(30), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=True),
        sa.Column("note", sa.String(500), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    for column in ("request_id", "actor_user_id", "action"):
        op.create_index(f"ix_request_actions_{column}", "request_actions", [column])


def downgrade() -> None:
    op.drop_table("request_actions")
    op.drop_table("financial_requests")
    with op.batch_alter_table("categories") as batch_op:
        batch_op.drop_index("ix_categories_delegated_user_id")
        batch_op.drop_constraint("fk_categories_delegated_user_id", type_="foreignkey")
        batch_op.drop_column("delegated_user_id")
    op.drop_table("resource_grants")
    op.drop_table("capability_grants")
    op.drop_table("budget_access_profiles")
