"""Add optional type-appropriate debt terms."""

import sqlalchemy as sa
from alembic import op


revision = "0026_debt_terms"
down_revision = "0025_request_lifecycle"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "account_debt_terms",
        sa.Column("account_id", sa.String(length=36), nullable=False),
        sa.Column("budget_id", sa.String(length=36), nullable=False),
        sa.Column("terms_type", sa.String(length=30), nullable=False),
        sa.Column("annual_rate_basis_points", sa.Integer(), nullable=True),
        sa.Column("rate_type", sa.String(length=20), nullable=True),
        sa.Column("payment_frequency", sa.String(length=20), nullable=True),
        sa.Column("scheduled_payment_minor", sa.BigInteger(), nullable=True),
        sa.Column("minimum_payment_rule", sa.String(length=20), nullable=True),
        sa.Column("minimum_payment_minor", sa.BigInteger(), nullable=True),
        sa.Column("minimum_payment_rate_basis_points", sa.Integer(), nullable=True),
        sa.Column("due_day", sa.Integer(), nullable=True),
        sa.Column("statement_day", sa.Integer(), nullable=True),
        sa.Column("original_principal_minor", sa.BigInteger(), nullable=True),
        sa.Column("original_term_months", sa.Integer(), nullable=True),
        sa.Column("remaining_term_months", sa.Integer(), nullable=True),
        sa.Column("promotional_rate_basis_points", sa.Integer(), nullable=True),
        sa.Column("promotional_ends_on", sa.Date(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("account_id"),
    )
    op.create_index("ix_account_debt_terms_budget_id", "account_debt_terms", ["budget_id"])


def downgrade() -> None:
    op.drop_table("account_debt_terms")
