"""Add immutable, attributed category target history."""
import sqlalchemy as sa
from alembic import op

revision = "0039_target_revisions"
down_revision = "0038_debt_payoff_plan"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "category_target_revisions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("budget_id", sa.String(length=36), nullable=False),
        sa.Column("category_id", sa.String(length=36), nullable=False),
        sa.Column("target_id", sa.String(length=36), nullable=True),
        sa.Column("action", sa.String(length=20), nullable=False),
        sa.Column("actor_user_id", sa.String(length=36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=True),
        sa.Column("affected_month", sa.Date(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('created', 'updated', 'deleted', 'snoozed', 'resumed')", name="ck_target_revision_action"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["category_id"], ["categories.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_category_target_revisions_budget_id", "category_target_revisions", ["budget_id"])
    op.create_index("ix_category_target_revisions_category_id", "category_target_revisions", ["category_id"])
    op.create_index("ix_category_target_revisions_target_id", "category_target_revisions", ["target_id"])
    op.create_index("ix_category_target_revisions_actor_user_id", "category_target_revisions", ["actor_user_id"])
    op.create_index("ix_category_target_revisions_created_at", "category_target_revisions", ["created_at"])
    op.create_index("ix_target_revision_category_created", "category_target_revisions", ["category_id", "created_at"])

    # Existing targets receive one conservative creation observation using facts already stored.
    connection = op.get_bind()
    targets = sa.table(
        "category_targets",
        sa.column("id", sa.String), sa.column("budget_id", sa.String), sa.column("category_id", sa.String),
        sa.column("target_type", sa.String), sa.column("target_amount_minor", sa.BigInteger),
        sa.column("target_date", sa.Date), sa.column("recurrence_months", sa.Integer),
        sa.column("minimum_contribution_minor", sa.BigInteger), sa.column("priority", sa.Integer),
        sa.column("is_active", sa.Boolean), sa.column("created_by_user_id", sa.String),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    revisions = sa.table(
        "category_target_revisions",
        sa.column("id", sa.String), sa.column("budget_id", sa.String), sa.column("category_id", sa.String),
        sa.column("target_id", sa.String), sa.column("action", sa.String), sa.column("actor_user_id", sa.String),
        sa.column("before_snapshot", sa.JSON), sa.column("after_snapshot", sa.JSON),
        sa.column("affected_month", sa.Date), sa.column("created_at", sa.DateTime(timezone=True)),
    )
    import uuid
    rows = connection.execute(sa.select(targets)).mappings()
    for row in rows:
        snapshot = {key: row[key] for key in (
            "target_type", "target_amount_minor", "target_date", "recurrence_months",
            "minimum_contribution_minor", "priority", "is_active",
        )}
        if snapshot["target_date"] is not None:
            snapshot["target_date"] = snapshot["target_date"].isoformat()
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], category_id=row["category_id"],
            target_id=row["id"], action="created", actor_user_id=row["created_by_user_id"],
            before_snapshot=None, after_snapshot=snapshot, affected_month=None, created_at=row["created_at"],
        ))


def downgrade():
    op.drop_index("ix_target_revision_category_created", table_name="category_target_revisions")
    op.drop_index("ix_category_target_revisions_created_at", table_name="category_target_revisions")
    op.drop_index("ix_category_target_revisions_actor_user_id", table_name="category_target_revisions")
    op.drop_index("ix_category_target_revisions_target_id", table_name="category_target_revisions")
    op.drop_index("ix_category_target_revisions_category_id", table_name="category_target_revisions")
    op.drop_index("ix_category_target_revisions_budget_id", table_name="category_target_revisions")
    op.drop_table("category_target_revisions")
