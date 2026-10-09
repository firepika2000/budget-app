"""Add immutable allowance plan lifecycle history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0045_allowance_plan_history"
down_revision = "0044_payee_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "allowance_plan_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("plan_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "action IN ('created', 'paused', 'reactivated', 'issued')",
            name="ck_allowance_plan_revision_action",
        ),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("budget_id", "plan_id", "actor_user_id", "created_at"):
        op.create_index(
            f"ix_allowance_plan_revisions_{field}", "allowance_plan_revisions", [field]
        )
    op.create_index(
        "ix_allowance_plan_revision_plan_created",
        "allowance_plan_revisions",
        ["plan_id", "created_at"],
    )

    connection = op.get_bind()
    plans = sa.table(
        "allowance_plans",
        sa.column("id"), sa.column("budget_id"), sa.column("delegated_user_id"),
        sa.column("source_category_id"), sa.column("name"), sa.column("amount_minor"),
        sa.column("next_issue_date"), sa.column("recurrence_unit"),
        sa.column("interval_count"), sa.column("rollover_policy"), sa.column("is_active"),
        sa.column("created_by_user_id"), sa.column("created_at"),
    )
    splits = sa.table(
        "allowance_splits",
        sa.column("id"), sa.column("plan_id"), sa.column("destination_category_id"),
        sa.column("amount_minor"),
    )
    revisions = sa.table(
        "allowance_plan_revisions",
        sa.column("id"), sa.column("budget_id"), sa.column("plan_id"),
        sa.column("action"), sa.column("actor_user_id"),
        sa.column("before_snapshot", sa.JSON()), sa.column("after_snapshot", sa.JSON()),
        sa.column("created_at"),
    )
    splits_by_plan: dict[str, list[dict]] = {}
    for row in connection.execute(
        sa.select(splits).order_by(splits.c.destination_category_id, splits.c.id)
    ).mappings():
        splits_by_plan.setdefault(row["plan_id"], []).append({
            "destination_category_id": row["destination_category_id"],
            "amount_minor": row["amount_minor"],
        })
    for row in connection.execute(sa.select(plans)).mappings():
        snapshot = {
            "delegated_user_id": row["delegated_user_id"],
            "source_category_id": row["source_category_id"],
            "name": row["name"],
            "amount_minor": row["amount_minor"],
            "next_issue_date": (
                row["next_issue_date"].isoformat()
                if hasattr(row["next_issue_date"], "isoformat")
                else str(row["next_issue_date"])
            ),
            "recurrence_unit": row["recurrence_unit"],
            "interval_count": row["interval_count"],
            "rollover_policy": row["rollover_policy"],
            "is_active": bool(row["is_active"]),
            "splits": splits_by_plan.get(row["id"], []),
        }
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], plan_id=row["id"],
            action="created", actor_user_id=row["created_by_user_id"],
            before_snapshot=None, after_snapshot=snapshot, created_at=row["created_at"],
        ))


def downgrade():
    op.drop_index("ix_allowance_plan_revision_plan_created", table_name="allowance_plan_revisions")
    for field in reversed(("budget_id", "plan_id", "actor_user_id", "created_at")):
        op.drop_index(
            f"ix_allowance_plan_revisions_{field}", table_name="allowance_plan_revisions"
        )
    op.drop_table("allowance_plan_revisions")
