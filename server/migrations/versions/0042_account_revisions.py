"""Add immutable account lifecycle history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0042_account_revisions"
down_revision = "0041_delegated_policy_revs"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "account_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("account_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('created', 'updated')", name="ck_account_revision_action"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("budget_id", "account_id", "actor_user_id", "created_at"):
        op.create_index(f"ix_account_revisions_{field}", "account_revisions", [field])
    op.create_index("ix_account_revision_account_created", "account_revisions", ["account_id", "created_at"])

    connection = op.get_bind()
    accounts = sa.table("accounts", *[sa.column(name) for name in (
        "id", "budget_id", "name", "account_type", "is_on_budget", "is_closed",
        "payment_category_id", "created_at",
    )])
    budgets = sa.table("budgets", sa.column("id"), sa.column("household_id"))
    memberships = sa.table("memberships", sa.column("household_id"), sa.column("user_id"), sa.column("role"))
    revisions = sa.table(
        "account_revisions",
        sa.column("id", sa.String), sa.column("budget_id", sa.String),
        sa.column("account_id", sa.String), sa.column("action", sa.String),
        sa.column("actor_user_id", sa.String), sa.column("before_snapshot", sa.JSON),
        sa.column("after_snapshot", sa.JSON), sa.column("created_at"),
    )
    owner_by_budget = {
        row["budget_id"]: row["user_id"]
        for row in connection.execute(sa.select(
            budgets.c.id.label("budget_id"), memberships.c.user_id,
        ).select_from(budgets.join(
            memberships,
            sa.and_(memberships.c.household_id == budgets.c.household_id, memberships.c.role == "owner"),
        ))).mappings()
    }
    for row in connection.execute(sa.select(accounts)).mappings():
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], account_id=row["id"],
            action="created", actor_user_id=owner_by_budget[row["budget_id"]], before_snapshot=None,
            after_snapshot={
                "name": row["name"], "account_type": row["account_type"],
                "is_on_budget": bool(row["is_on_budget"]), "is_closed": bool(row["is_closed"]),
                "payment_category_id": row["payment_category_id"],
            },
            created_at=row["created_at"],
        ))


def downgrade():
    op.drop_index("ix_account_revision_account_created", table_name="account_revisions")
    for field in reversed(("budget_id", "account_id", "actor_user_id", "created_at")):
        op.drop_index(f"ix_account_revisions_{field}", table_name="account_revisions")
    op.drop_table("account_revisions")
