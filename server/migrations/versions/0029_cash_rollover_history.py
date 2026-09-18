"""Preserve explicit legacy cash-rollover provenance; do not change financial behavior."""
from datetime import date, datetime, timezone
from uuid import NAMESPACE_URL, uuid5

import sqlalchemy as sa
from alembic import op

revision = "0029_cash_rollover_history"
down_revision = "0028_target_snoozes"
branch_labels = None
depends_on = None


def upgrade() -> None:
    table = op.create_table(
        "cash_rollover_policy_changes",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("budget_id", sa.String(36), nullable=False),
        sa.Column("effective_month", sa.Date(), nullable=False),
        sa.Column("policy", sa.String(30), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("source", sa.String(30), nullable=False),
        sa.Column("actor_user_id", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["budget_id"], ["budgets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.UniqueConstraint("budget_id", "version", name="uq_cash_rollover_budget_version"),
        sa.CheckConstraint("version >= 0", name="ck_cash_rollover_version"),
        sa.CheckConstraint("policy IN ('absorb_next_month', 'carry_category_deficit')", name="ck_cash_rollover_policy"),
        sa.CheckConstraint("source IN ('legacy_migration', 'budget_creation', 'user_selection')", name="ck_cash_rollover_source"),
        sa.CheckConstraint("source = 'legacy_migration' OR actor_user_id IS NOT NULL", name="ck_cash_rollover_actor"),
        sa.CheckConstraint(sa.extract("day", sa.column("effective_month")) == 1, name="ck_cash_rollover_month"),
    )
    op.create_index("ix_cash_rollover_budget_effective", table.name, ["budget_id", "effective_month", "version"])
    # Legacy facts can predate budget creation/import. The baseline covers the whole supported
    # date domain, but is explicitly attributed to this migration, never a fabricated user action.
    now = datetime.now(timezone.utc)
    connection = op.get_bind()
    budgets = connection.execute(sa.text("SELECT id FROM budgets").execution_options(yield_per=500))
    while rows := budgets.fetchmany(500):
        connection.execute(table.insert(), [
            {"id": str(uuid5(NAMESPACE_URL, f"budget-cash-policy:{row.id}:legacy")),
             "budget_id": row.id, "effective_month": date(1, 1, 1),
             "policy": "carry_category_deficit", "version": 0, "source": "legacy_migration",
             "actor_user_id": None, "created_at": now}
            for row in rows
        ])


def downgrade() -> None:
    # A later policy-aware release must not lose decisions and silently reinterpret periods.
    count = op.get_bind().execute(sa.text(
        "SELECT COUNT(*) FROM cash_rollover_policy_changes WHERE source <> 'legacy_migration'"
    )).scalar_one()
    if count:
        raise RuntimeError("Cannot remove cash rollover history containing policy decisions; restore a compatible backup to a new destination instead")
    # Baseline-only metadata is safe to remove. Financial ledgers are not rewritten.
    op.drop_index("ix_cash_rollover_budget_effective", table_name="cash_rollover_policy_changes")
    op.drop_table("cash_rollover_policy_changes")
