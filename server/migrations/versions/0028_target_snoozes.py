"""Add month-scoped target guidance snoozes without changing financial rows."""
import sqlalchemy as sa
from alembic import op

revision = "0028_target_snoozes"
down_revision = "0027_interest_class"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "category_target_snoozes",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("target_id", sa.String(36), nullable=False),
        sa.Column("month", sa.Date(), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["target_id"], ["category_targets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["created_by_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("target_id", "month", name="uq_target_snooze_month"),
    )
    for field in ("budget_id", "target_id", "month"):
        op.create_index(f"ix_category_target_snoozes_{field}", "category_target_snoozes", [field])


def downgrade() -> None:
    for field in ("month", "target_id", "budget_id"):
        op.drop_index(f"ix_category_target_snoozes_{field}", table_name="category_target_snoozes")
    op.drop_table("category_target_snoozes")
