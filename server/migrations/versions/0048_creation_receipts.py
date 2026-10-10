"""Bind creation retry identities to immutable original request observations."""
import sqlalchemy as sa
from alembic import op

revision = "0048_creation_receipts"
down_revision = "0047_payoff_plan_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("transaction_creation_receipts",
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("operation_id", sa.String(36), nullable=False),
        sa.Column("transaction_id", sa.String(36), nullable=False),
        sa.Column("request_digest", sa.String(67), nullable=True),
        sa.PrimaryKeyConstraint("budget_id", "actor_user_id", "operation_id"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"))
    # Do not invent an original payload from a transaction that may have been edited.
    op.execute(sa.text("""INSERT INTO transaction_creation_receipts
        (budget_id, actor_user_id, operation_id, transaction_id, request_digest)
        SELECT budget_id, created_by_user_id, client_operation_id, id, NULL
        FROM transactions WHERE client_operation_id IS NOT NULL"""))


def downgrade():
    op.drop_table("transaction_creation_receipts")
