"""Add composite indexes for bounded historical report scans."""

from alembic import op


revision = "0022_report_query_indexes"
down_revision = "0021_scheduled_payee_id"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index("ix_transaction_budget_date_id", "transactions", ["budget_id", "occurred_on", "id"])
    op.create_index("ix_allocation_operation_budget_date", "allocation_operations", ["budget_id", "occurred_on", "id"])
    op.create_index("ix_allocation_posting_budget_operation", "allocation_postings", ["budget_id", "operation_id"])
    op.create_index("ix_reserve_event_budget_date", "credit_card_reserve_events", ["budget_id", "occurred_on", "id"])
    op.create_index("ix_scheduled_budget_active_date", "scheduled_transactions", ["budget_id", "is_active", "next_date"])


def downgrade() -> None:
    op.drop_index("ix_scheduled_budget_active_date", table_name="scheduled_transactions")
    op.drop_index("ix_reserve_event_budget_date", table_name="credit_card_reserve_events")
    op.drop_index("ix_allocation_posting_budget_operation", table_name="allocation_postings")
    op.drop_index("ix_allocation_operation_budget_date", table_name="allocation_operations")
    op.drop_index("ix_transaction_budget_date_id", table_name="transactions")
