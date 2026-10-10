"""Add immutable, attributed scheduled-transaction decision history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0040_schedule_revisions"
down_revision = "0039_target_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "scheduled_transaction_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("schedule_id", sa.String(36), nullable=False),
        sa.Column("before_account_id", sa.String(36), nullable=True),
        sa.Column("before_destination_account_id", sa.String(36), nullable=True),
        sa.Column("before_category_id", sa.String(36), nullable=True),
        sa.Column("account_id", sa.String(36), nullable=False),
        sa.Column("destination_account_id", sa.String(36), nullable=True),
        sa.Column("category_id", sa.String(36), nullable=True),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=True),
        sa.Column("transaction_ids", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('created', 'updated', 'paused', 'resumed', 'deleted', 'realized')", name="ck_schedule_revision_action"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["before_account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["before_destination_account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["before_category_id"], ["categories.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["destination_account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["category_id"], ["categories.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    indexed_fields = ("budget_id", "schedule_id", "before_account_id", "before_destination_account_id", "before_category_id", "account_id", "destination_account_id", "category_id", "actor_user_id", "created_at")
    for field in indexed_fields:
        # Mark convention-derived names so SQLAlchemy applies the same deterministic
        # PostgreSQL identifier truncation as the ORM's index=True definitions.
        op.create_index(op.f(f"ix_scheduled_transaction_revisions_{field}"), "scheduled_transaction_revisions", [field])
    op.create_index("ix_schedule_revision_budget_created", "scheduled_transaction_revisions", ["budget_id", "created_at"])

    connection = op.get_bind()
    schedules = sa.table("scheduled_transactions", *[
        sa.column(name) for name in (
            "id", "budget_id", "account_id", "destination_account_id", "category_id", "payee_id", "name",
            "amount_minor", "next_date", "recurrence_unit", "interval_count", "end_date", "remaining_occurrences",
            "memo", "financial_classification", "is_active", "last_realized_on", "created_by_user_id", "created_at",
        )
    ])
    revisions = sa.table(
        "scheduled_transaction_revisions",
        sa.column("id", sa.String), sa.column("budget_id", sa.String), sa.column("schedule_id", sa.String),
        sa.column("before_account_id", sa.String), sa.column("before_destination_account_id", sa.String),
        sa.column("before_category_id", sa.String), sa.column("account_id", sa.String),
        sa.column("destination_account_id", sa.String), sa.column("category_id", sa.String),
        sa.column("action", sa.String), sa.column("actor_user_id", sa.String),
        sa.column("before_snapshot", sa.JSON), sa.column("after_snapshot", sa.JSON),
        sa.column("transaction_ids", sa.JSON), sa.column("created_at"),
    )
    for row in connection.execute(sa.select(schedules)).mappings():
        snapshot = {key: row[key] for key in (
            "account_id", "destination_account_id", "category_id", "payee_id", "name", "amount_minor", "next_date",
            "recurrence_unit", "interval_count", "end_date", "remaining_occurrences", "memo",
            "financial_classification", "is_active", "last_realized_on",
        )}
        for key in ("next_date", "end_date", "last_realized_on"):
            if snapshot[key] is not None:
                snapshot[key] = snapshot[key].isoformat() if hasattr(snapshot[key], "isoformat") else str(snapshot[key])
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], schedule_id=row["id"], account_id=row["account_id"],
            destination_account_id=row["destination_account_id"], category_id=row["category_id"], action="created",
            actor_user_id=row["created_by_user_id"], before_snapshot=None, after_snapshot=snapshot,
            transaction_ids=None, created_at=row["created_at"],
        ))


def downgrade():
    op.drop_index("ix_schedule_revision_budget_created", table_name="scheduled_transaction_revisions")
    for field in reversed(("budget_id", "schedule_id", "before_account_id", "before_destination_account_id", "before_category_id", "account_id", "destination_account_id", "category_id", "actor_user_id", "created_at")):
        op.drop_index(op.f(f"ix_scheduled_transaction_revisions_{field}"), table_name="scheduled_transaction_revisions")
    op.drop_table("scheduled_transaction_revisions")
