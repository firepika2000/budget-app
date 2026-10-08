"""Preserve append-only account reconciliation history."""
from datetime import datetime
from uuid import uuid4

import sqlalchemy as sa
from alembic import op

revision = "0037_reconciliation_history"
down_revision = "0036_category_resilience"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "reconciliations",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("budget_id", sa.String(length=36), nullable=False),
        sa.Column("account_id", sa.String(length=36), nullable=False),
        sa.Column("actor_user_id", sa.String(length=36), nullable=False),
        sa.Column("statement_date", sa.Date(), nullable=False),
        sa.Column("statement_balance_minor", sa.BigInteger(), nullable=False),
        sa.Column("cleared_balance_before_minor", sa.BigInteger(), nullable=False),
        sa.Column("reconciled_transaction_count", sa.Integer(), nullable=False),
        sa.Column("adjustment_transaction_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["adjustment_transaction_id"], ["transactions.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_reconciliations_budget_id", "reconciliations", ["budget_id"])
    op.create_index("ix_reconciliations_account_id", "reconciliations", ["account_id"])
    op.create_index("ix_reconciliations_actor_user_id", "reconciliations", ["actor_user_id"])
    op.create_index("ix_reconciliations_account_date", "reconciliations", ["account_id", "statement_date", "created_at"])
    bind = op.get_bind()
    rows = bind.execute(sa.text("""
        SELECT a.id AS account_id, a.budget_id, a.reconciled_balance_minor, a.reconciled_at,
               h.owner_user_id
        FROM accounts a
        JOIN budgets b ON b.id = a.budget_id
        JOIN households h ON h.id = b.household_id
        WHERE a.reconciled_at IS NOT NULL AND a.reconciled_balance_minor IS NOT NULL
    """)).mappings()
    for row in rows:
        stamp = row["reconciled_at"]
        if isinstance(stamp, str):
            stamp = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        bind.execute(sa.text("""
            INSERT INTO reconciliations
              (id, budget_id, account_id, actor_user_id, statement_date,
               statement_balance_minor, cleared_balance_before_minor,
               reconciled_transaction_count, adjustment_transaction_id, created_at)
            VALUES
              (:id, :budget_id, :account_id, :actor_user_id, :statement_date,
               :balance, :balance, 0, NULL, :created_at)
        """), {
            "id": str(uuid4()), "budget_id": row["budget_id"], "account_id": row["account_id"],
            "actor_user_id": row["owner_user_id"], "statement_date": stamp.date(),
            "balance": row["reconciled_balance_minor"], "created_at": stamp,
        })


def downgrade():
    op.drop_index("ix_reconciliations_account_date", table_name="reconciliations")
    op.drop_index("ix_reconciliations_actor_user_id", table_name="reconciliations")
    op.drop_index("ix_reconciliations_account_id", table_name="reconciliations")
    op.drop_index("ix_reconciliations_budget_id", table_name="reconciliations")
    op.drop_table("reconciliations")
