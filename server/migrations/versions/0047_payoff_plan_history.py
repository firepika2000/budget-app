"""Keep private saved-scenario decisions after updates and reset."""
import json
import uuid
import sqlalchemy as sa
from alembic import op

revision = "0047_payoff_plan_history"
down_revision = "0046_debt_terms_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("debt_payoff_plan_revisions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("before_snapshot", sa.JSON()), sa.Column("after_snapshot", sa.JSON()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('created', 'updated', 'deleted')", name="ck_payoff_plan_revision_action"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="RESTRICT"))
    for field in ("budget_id", "user_id", "created_at"):
        op.create_index(f"ix_debt_payoff_plan_revisions_{field}", "debt_payoff_plan_revisions", [field])
    connection = op.get_bind()
    table = sa.table("debt_payoff_plan_revisions", sa.column("id"), sa.column("budget_id"),
        sa.column("user_id"), sa.column("action"), sa.column("before_snapshot", sa.JSON()),
        sa.column("after_snapshot", sa.JSON()), sa.column("created_at"))
    for row in connection.execute(sa.text("SELECT * FROM debt_payoff_plans")).mappings():
        snapshot = {key: row[key] for key in ("strategy", "rollover", "extra_payment_minor", "account_ids", "custom_order", "target_date")}
        snapshot["rollover"] = bool(snapshot["rollover"])
        for key in ("account_ids", "custom_order"):
            if isinstance(snapshot[key], str): snapshot[key] = json.loads(snapshot[key])
        if hasattr(snapshot["target_date"], "isoformat"): snapshot["target_date"] = snapshot["target_date"].isoformat()
        connection.execute(table.insert().values(id=str(uuid.uuid4()), budget_id=row["budget_id"],
            user_id=row["user_id"], action="created", before_snapshot=None, after_snapshot=snapshot, created_at=row["updated_at"]))


def downgrade():
    for field in ("created_at", "user_id", "budget_id"):
        op.drop_index(f"ix_debt_payoff_plan_revisions_{field}", table_name="debt_payoff_plan_revisions")
    op.drop_table("debt_payoff_plan_revisions")
