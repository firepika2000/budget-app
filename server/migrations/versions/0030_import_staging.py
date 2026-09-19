"""Money-neutral import review staging, without changing financial rows."""
import sqlalchemy as sa
from alembic import op

revision = "0030_import_staging"
down_revision = "0029_cash_rollover_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "import_batches",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("candidate_count", sa.Integer(), nullable=False),
        sa.Column("candidates", sa.JSON(), nullable=False),
        sa.Column("source_format", sa.String(10), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('review', 'approved', 'cancelled')", name="ck_import_batch_status"),
        sa.CheckConstraint("version >= 0", name="ck_import_batch_version"),
        sa.CheckConstraint("candidate_count >= 0 AND candidate_count <= 10000", name="ck_import_batch_count"),
    )
    op.create_index("ix_import_batch_budget_actor", "import_batches", ["budget_id", "created_by_user_id", "created_at"])


def downgrade():
    if op.get_bind().execute(sa.text("SELECT COUNT(*) FROM import_batches")).scalar():
        raise RuntimeError("Cannot remove populated import staging; preserve review history")
    op.drop_index("ix_import_batch_budget_actor", table_name="import_batches")
    op.drop_table("import_batches")
