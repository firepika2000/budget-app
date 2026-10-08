"""Add immutable category and category-group metadata history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0043_structure_revisions"
down_revision = "0042_account_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "budget_structure_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("resource_type", sa.String(20), nullable=False),
        sa.Column("resource_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("resource_type IN ('category_group', 'category')", name="ck_structure_revision_resource_type"),
        sa.CheckConstraint("action IN ('created', 'updated')", name="ck_structure_revision_action"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("budget_id", "resource_type", "resource_id", "actor_user_id", "created_at"):
        op.create_index(f"ix_budget_structure_revisions_{field}", "budget_structure_revisions", [field])
    op.create_index("ix_structure_revision_resource_created", "budget_structure_revisions",
                    ["resource_type", "resource_id", "created_at"])

    connection = op.get_bind()
    revisions = sa.table("budget_structure_revisions", *[
        sa.column("id"), sa.column("budget_id"), sa.column("resource_type"),
        sa.column("resource_id"), sa.column("action"), sa.column("actor_user_id"),
        sa.column("before_snapshot", sa.JSON()), sa.column("after_snapshot", sa.JSON()),
        sa.column("created_at"),
    ])
    budgets = sa.table("budgets", sa.column("id"), sa.column("household_id"), sa.column("created_at"))
    memberships = sa.table("memberships", sa.column("household_id"), sa.column("user_id"), sa.column("role"))
    groups = sa.table("category_groups", sa.column("id"), sa.column("budget_id"), sa.column("name"),
                      sa.column("sort_order"), sa.column("is_archived"))
    categories = sa.table(
        "categories", sa.column("id"), sa.column("budget_id"), sa.column("group_id"), sa.column("name"),
        sa.column("icon_name"), sa.column("note"), sa.column("sort_order"), sa.column("is_archived"),
        sa.column("is_essential"), sa.column("is_emergency_fund"), sa.column("delegated_user_id"),
    )
    budget_rows = list(connection.execute(sa.select(budgets)).mappings())
    owner_by_budget = {
        row["budget_id"]: row["user_id"]
        for row in connection.execute(sa.select(
            budgets.c.id.label("budget_id"), memberships.c.user_id,
        ).select_from(budgets.join(
            memberships, sa.and_(memberships.c.household_id == budgets.c.household_id,
                                 memberships.c.role == "owner"),
        ))).mappings()
    }
    created_by_budget = {row["id"]: row["created_at"] for row in budget_rows}
    for row in connection.execute(sa.select(groups)).mappings():
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], resource_type="category_group",
            resource_id=row["id"], action="created", actor_user_id=owner_by_budget[row["budget_id"]],
            before_snapshot=None, after_snapshot={
                "name": row["name"], "sort_order": row["sort_order"], "is_archived": bool(row["is_archived"]),
            }, created_at=created_by_budget[row["budget_id"]],
        ))
    for row in connection.execute(sa.select(categories)).mappings():
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], resource_type="category",
            resource_id=row["id"], action="created", actor_user_id=owner_by_budget[row["budget_id"]],
            before_snapshot=None, after_snapshot={
                "group_id": row["group_id"], "name": row["name"], "icon_name": row["icon_name"],
                "note": row["note"], "sort_order": row["sort_order"],
                "is_archived": bool(row["is_archived"]), "is_essential": bool(row["is_essential"]),
                "is_emergency_fund": bool(row["is_emergency_fund"]),
                "delegated_user_id": row["delegated_user_id"],
            }, created_at=created_by_budget[row["budget_id"]],
        ))


def downgrade():
    op.drop_index("ix_structure_revision_resource_created", table_name="budget_structure_revisions")
    for field in reversed(("budget_id", "resource_type", "resource_id", "actor_user_id", "created_at")):
        op.drop_index(f"ix_budget_structure_revisions_{field}", table_name="budget_structure_revisions")
    op.drop_table("budget_structure_revisions")
