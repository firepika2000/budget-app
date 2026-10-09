"""Preserve immutable debt-term planning decisions."""
import uuid

import sqlalchemy as sa
from alembic import op

revision = "0046_debt_terms_history"
down_revision = "0045_allowance_plan_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "account_debt_terms_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("account_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=False),
        sa.Column("before_snapshot", sa.JSON(), nullable=True),
        sa.Column("after_snapshot", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "action IN ('created', 'updated', 'deleted')",
            name="ck_account_debt_terms_revision_action",
        ),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
    )
    for field in ("budget_id", "account_id", "actor_user_id", "created_at"):
        op.create_index(
            f"ix_account_debt_terms_revisions_{field}",
            "account_debt_terms_revisions", [field],
        )
    op.create_index(
        "ix_debt_terms_revision_account_created",
        "account_debt_terms_revisions", ["account_id", "created_at"],
    )

    connection = op.get_bind()
    terms = sa.table(
        "account_debt_terms",
        sa.column("account_id"), sa.column("budget_id"), sa.column("terms_type"),
        sa.column("annual_rate_basis_points"), sa.column("rate_type"),
        sa.column("payment_frequency"), sa.column("scheduled_payment_minor"),
        sa.column("minimum_payment_rule"), sa.column("minimum_payment_minor"),
        sa.column("minimum_payment_rate_basis_points"), sa.column("due_day"),
        sa.column("statement_day"), sa.column("original_principal_minor"),
        sa.column("original_term_months"), sa.column("remaining_term_months"),
        sa.column("promotional_rate_basis_points"), sa.column("promotional_ends_on"),
        sa.column("updated_at"),
    )
    budgets = sa.table("budgets", sa.column("id"), sa.column("household_id"))
    memberships = sa.table(
        "memberships", sa.column("household_id"), sa.column("user_id"),
        sa.column("role"), sa.column("is_active"),
    )
    revisions = sa.table(
        "account_debt_terms_revisions",
        sa.column("id"), sa.column("budget_id"), sa.column("account_id"),
        sa.column("action"), sa.column("actor_user_id"),
        sa.column("before_snapshot", sa.JSON()), sa.column("after_snapshot", sa.JSON()),
        sa.column("created_at"),
    )
    owner_by_budget = dict(connection.execute(
        sa.select(budgets.c.id, memberships.c.user_id).join(
            memberships, memberships.c.household_id == budgets.c.household_id
        ).where(memberships.c.role == "owner", memberships.c.is_active.is_(True))
    ).all())
    snapshot_fields = (
        "terms_type", "annual_rate_basis_points", "rate_type", "payment_frequency",
        "scheduled_payment_minor", "minimum_payment_rule", "minimum_payment_minor",
        "minimum_payment_rate_basis_points", "due_day", "statement_day",
        "original_principal_minor", "original_term_months", "remaining_term_months",
        "promotional_rate_basis_points", "promotional_ends_on",
    )
    for row in connection.execute(sa.select(terms)).mappings():
        snapshot = {field: row[field] for field in snapshot_fields}
        if snapshot["promotional_ends_on"] is not None:
            value = snapshot["promotional_ends_on"]
            snapshot["promotional_ends_on"] = value.isoformat() if hasattr(value, "isoformat") else str(value)
        connection.execute(revisions.insert().values(
            id=str(uuid.uuid4()), budget_id=row["budget_id"], account_id=row["account_id"],
            action="created", actor_user_id=owner_by_budget[row["budget_id"]],
            before_snapshot=None, after_snapshot=snapshot, created_at=row["updated_at"],
        ))


def downgrade():
    op.drop_index("ix_debt_terms_revision_account_created", table_name="account_debt_terms_revisions")
    for field in reversed(("budget_id", "account_id", "actor_user_id", "created_at")):
        op.drop_index(
            f"ix_account_debt_terms_revisions_{field}",
            table_name="account_debt_terms_revisions",
        )
    op.drop_table("account_debt_terms_revisions")
