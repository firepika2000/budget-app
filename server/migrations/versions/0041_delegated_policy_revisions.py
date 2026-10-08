"""Add immutable, attributed delegated-authority decision history."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0041_delegated_policy_revs"
down_revision = "0040_schedule_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "delegated_budget_policy_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("policy_id", sa.String(36), nullable=False),
        sa.Column("member_user_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('created', 'updated')", name="ck_delegated_policy_revision_action"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["member_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("budget_id", "policy_id", "member_user_id", "actor_user_id", "created_at"):
        op.create_index(f"ix_delegated_budget_policy_revisions_{field}", "delegated_budget_policy_revisions", [field])
    op.create_index("ix_delegated_policy_revision_budget_created", "delegated_budget_policy_revisions", ["budget_id", "created_at"])

    connection = op.get_bind()
    policies = sa.table("delegated_budget_policies", *[sa.column(name) for name in (
        "id", "budget_id", "user_id", "pool_category_id", "authority_minor", "allow_category_creation",
        "allow_reallocation", "created_by_user_id", "updated_at",
    )])
    rules = sa.table("delegated_category_rules", *[sa.column(name) for name in (
        "policy_id", "category_id", "rule_kind", "minimum_minor", "maximum_minor",
    )])
    revisions = sa.table(
        "delegated_budget_policy_revisions",
        sa.column("id", sa.String), sa.column("budget_id", sa.String), sa.column("policy_id", sa.String),
        sa.column("member_user_id", sa.String), sa.column("action", sa.String),
        sa.column("actor_user_id", sa.String), sa.column("before_snapshot", sa.JSON),
        sa.column("after_snapshot", sa.JSON), sa.column("created_at"),
    )
    for row in connection.execute(sa.select(policies)).mappings():
        policy_rules = connection.execute(sa.select(rules).where(rules.c.policy_id == row["id"])).mappings().all()
        snapshot = {
            "user_id": row["user_id"], "pool_category_id": row["pool_category_id"],
            "authority_minor": row["authority_minor"],
            "allow_category_creation": bool(row["allow_category_creation"]),
            "allow_reallocation": bool(row["allow_reallocation"]),
            "rules": sorted([{
                "category_id": item["category_id"], "rule_kind": item["rule_kind"],
                "minimum_minor": item["minimum_minor"], "maximum_minor": item["maximum_minor"],
            } for item in policy_rules], key=lambda item: (item["category_id"], item["rule_kind"])),
        }
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], policy_id=row["id"],
            member_user_id=row["user_id"], action="created", actor_user_id=row["created_by_user_id"],
            before_snapshot=None, after_snapshot=snapshot, created_at=row["updated_at"],
        ))


def downgrade():
    op.drop_index("ix_delegated_policy_revision_budget_created", table_name="delegated_budget_policy_revisions")
    for field in reversed(("budget_id", "policy_id", "member_user_id", "actor_user_id", "created_at")):
        op.drop_index(f"ix_delegated_budget_policy_revisions_{field}", table_name="delegated_budget_policy_revisions")
    op.drop_table("delegated_budget_policy_revisions")
