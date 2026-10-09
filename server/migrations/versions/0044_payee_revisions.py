"""Add immutable Payee identity and preference history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0044_payee_revisions"
down_revision = "0043_structure_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "payee_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("household_id", sa.String(36), nullable=False),
        sa.Column("budget_id", sa.String(36), nullable=True),
        sa.Column("payee_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(30), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "action IN ('created', 'updated', 'alias_added', 'alias_removed', 'merged', 'preference_updated')",
            name="ck_payee_revision_action",
        ),
        sa.ForeignKeyConstraint(["household_id"], ["households.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("household_id", "budget_id", "payee_id", "actor_user_id", "created_at"):
        op.create_index(f"ix_payee_revisions_{field}", "payee_revisions", [field])
    op.create_index("ix_payee_revision_payee_created", "payee_revisions", ["payee_id", "created_at"])

    connection = op.get_bind()
    revisions = sa.table(
        "payee_revisions",
        sa.column("id"), sa.column("household_id"), sa.column("budget_id"), sa.column("payee_id"),
        sa.column("action"), sa.column("actor_user_id"), sa.column("before_snapshot", sa.JSON()),
        sa.column("after_snapshot", sa.JSON()), sa.column("created_at"),
    )
    payees = sa.table(
        "payees", sa.column("id"), sa.column("household_id"), sa.column("display_name"),
        sa.column("is_archived"), sa.column("merged_into_payee_id"), sa.column("created_by_user_id"),
        sa.column("created_at"),
    )
    aliases = sa.table("payee_aliases", sa.column("payee_id"), sa.column("display_name"))
    preferences = sa.table(
        "payee_budget_preferences", sa.column("payee_id"), sa.column("budget_id"),
        sa.column("default_category_id"), sa.column("updated_by_user_id"), sa.column("updated_at"),
    )
    aliases_by_payee: dict[str, list[str]] = {}
    for row in connection.execute(sa.select(aliases).order_by(aliases.c.display_name)).mappings():
        aliases_by_payee.setdefault(row["payee_id"], []).append(row["display_name"])
    household_by_payee: dict[str, str] = {}
    for row in connection.execute(sa.select(payees)).mappings():
        household_by_payee[row["id"]] = row["household_id"]
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), household_id=row["household_id"], budget_id=None,
            payee_id=row["id"], action="created", actor_user_id=row["created_by_user_id"],
            before_snapshot=None, after_snapshot={
                "display_name": row["display_name"], "is_archived": bool(row["is_archived"]),
                "merged_into_payee_id": row["merged_into_payee_id"],
                "aliases": aliases_by_payee.get(row["id"], []),
            }, created_at=row["created_at"],
        ))
    for row in connection.execute(sa.select(preferences)).mappings():
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), household_id=household_by_payee[row["payee_id"]],
            budget_id=row["budget_id"], payee_id=row["payee_id"], action="preference_updated",
            actor_user_id=row["updated_by_user_id"], before_snapshot=None,
            after_snapshot={"default_category_id": row["default_category_id"]},
            created_at=row["updated_at"],
        ))


def downgrade():
    op.drop_index("ix_payee_revision_payee_created", table_name="payee_revisions")
    for field in reversed(("household_id", "budget_id", "payee_id", "actor_user_id", "created_at")):
        op.drop_index(f"ix_payee_revisions_{field}", table_name="payee_revisions")
    op.drop_table("payee_revisions")
