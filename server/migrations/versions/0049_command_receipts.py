"""Atomic receipts for identified workspace mutations."""
import sqlalchemy as sa
from alembic import op

revision = "0049_command_receipts"
down_revision = "0048_creation_receipts"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("workspace_command_receipts",
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("operation_id", sa.String(36), nullable=False),
        sa.Column("command_kind", sa.String(40), nullable=False),
        sa.Column("request_digest", sa.String(67), nullable=False),
        sa.Column("resource_id", sa.String(36), nullable=False),
        sa.PrimaryKeyConstraint("budget_id", "actor_user_id", "operation_id"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"))


def downgrade():
    op.drop_table("workspace_command_receipts")
