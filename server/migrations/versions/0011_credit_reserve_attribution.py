"""Attribute new credit reserve events to their spending category."""

from alembic import op
import sqlalchemy as sa


revision = "0011_credit_attribution"
down_revision = "0010_allowance_plans"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("credit_card_reserve_events") as batch_op:
        batch_op.add_column(sa.Column("spending_category_id", sa.String(36), nullable=True))
        batch_op.create_foreign_key(
            "fk_credit_reserve_spending_category_id",
            "categories",
            ["spending_category_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index(
            "ix_credit_card_reserve_events_spending_category_id",
            ["spending_category_id"],
        )

    # Direct legacy purchases are unambiguous. Split legacy purchases intentionally
    # remain unattributed rather than guessing and corrupting their audit history.
    op.execute(sa.text(
        "UPDATE credit_card_reserve_events "
        "SET spending_category_id = ("
        "SELECT category_id FROM transactions "
        "WHERE transactions.id = credit_card_reserve_events.source_transaction_id"
        ") WHERE source_transaction_id IS NOT NULL"
    ))


def downgrade() -> None:
    with op.batch_alter_table("credit_card_reserve_events") as batch_op:
        batch_op.drop_index("ix_credit_card_reserve_events_spending_category_id")
        batch_op.drop_constraint("fk_credit_reserve_spending_category_id", type_="foreignkey")
        batch_op.drop_column("spending_category_id")
