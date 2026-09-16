"""Add explicit actual-interest classification to posted activity."""

import sqlalchemy as sa
from alembic import op


revision = "0027_interest_class"
down_revision = "0026_debt_terms"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("transactions", sa.Column("financial_classification", sa.String(length=30), nullable=True))
    op.add_column("transaction_splits", sa.Column("financial_classification", sa.String(length=30), nullable=True))
    op.add_column("scheduled_transactions", sa.Column("financial_classification", sa.String(length=30), nullable=True))
    op.create_index("ix_transaction_budget_class_date", "transactions", ["budget_id", "financial_classification", "occurred_on"])
    op.create_index("ix_transaction_split_classification", "transaction_splits", ["financial_classification"])


def downgrade() -> None:
    op.drop_index("ix_transaction_split_classification", table_name="transaction_splits")
    op.drop_index("ix_transaction_budget_class_date", table_name="transactions")
    op.drop_column("scheduled_transactions", "financial_classification")
    op.drop_column("transaction_splits", "financial_classification")
    op.drop_column("transactions", "financial_classification")
