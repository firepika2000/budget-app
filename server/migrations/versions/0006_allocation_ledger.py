"""Add the append-only balanced allocation ledger and migrate assignments."""

from datetime import datetime, time, timezone
from uuid import uuid4

from alembic import op
import sqlalchemy as sa


revision = "0006_allocation_ledger"
down_revision = "0005_refresh_sessions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "budgets",
        sa.Column("allocation_version", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_table(
        "allocation_operations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("occurred_on", sa.Date(), nullable=False),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("note", sa.String(500), nullable=False),
        sa.Column("source", sa.String(30), nullable=False),
        sa.Column(
            "reversal_of_id",
            sa.String(36),
            sa.ForeignKey("allocation_operations.id", ondelete="RESTRICT"),
            nullable=True,
            unique=True,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_allocation_operations_budget_id", "allocation_operations", ["budget_id"])
    op.create_index("ix_allocation_operations_occurred_on", "allocation_operations", ["occurred_on"])
    op.create_index("ix_allocation_operations_kind", "allocation_operations", ["kind"])
    op.create_index("ix_allocation_operations_actor_user_id", "allocation_operations", ["actor_user_id"])
    op.create_table(
        "allocation_postings",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "operation_id",
            sa.String(36),
            sa.ForeignKey("allocation_operations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("bucket", sa.String(30), nullable=False),
        sa.Column("category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.CheckConstraint(
            "(bucket = 'category' AND category_id IS NOT NULL) OR "
            "(bucket = 'ready_to_assign' AND category_id IS NULL)",
            name="ck_allocation_posting_bucket_category",
        ),
        sa.CheckConstraint("amount_minor <> 0", name="ck_allocation_posting_nonzero"),
    )
    op.create_index("ix_allocation_postings_operation_id", "allocation_postings", ["operation_id"])
    op.create_index("ix_allocation_postings_budget_id", "allocation_postings", ["budget_id"])
    op.create_index("ix_allocation_postings_category_id", "allocation_postings", ["category_id"])

    bind = op.get_bind()
    assignments = sa.table(
        "monthly_assignments",
        sa.column("budget_id", sa.String),
        sa.column("category_id", sa.String),
        sa.column("month", sa.Date),
        sa.column("assigned_minor", sa.BigInteger),
    )
    budgets = sa.table(
        "budgets",
        sa.column("id", sa.String),
        sa.column("household_id", sa.String),
        sa.column("allocation_version", sa.Integer),
    )
    households = sa.table(
        "households",
        sa.column("id", sa.String),
        sa.column("owner_user_id", sa.String),
    )
    operations = sa.table(
        "allocation_operations",
        sa.column("id", sa.String),
        sa.column("budget_id", sa.String),
        sa.column("occurred_on", sa.Date),
        sa.column("kind", sa.String),
        sa.column("actor_user_id", sa.String),
        sa.column("note", sa.String),
        sa.column("source", sa.String),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    postings = sa.table(
        "allocation_postings",
        sa.column("id", sa.String),
        sa.column("operation_id", sa.String),
        sa.column("budget_id", sa.String),
        sa.column("bucket", sa.String),
        sa.column("category_id", sa.String),
        sa.column("amount_minor", sa.BigInteger),
    )
    rows = bind.execute(
        sa.select(
            assignments.c.budget_id,
            assignments.c.category_id,
            assignments.c.month,
            assignments.c.assigned_minor,
            households.c.owner_user_id,
        )
        .select_from(
            assignments.join(budgets, budgets.c.id == assignments.c.budget_id).join(
                households, households.c.id == budgets.c.household_id
            )
        )
    ).all()
    versions: dict[str, int] = {}
    for row in rows:
        if row.assigned_minor == 0:
            continue
        if row.assigned_minor == -(2**63):
            raise RuntimeError(
                "Cannot migrate an Int64.minimum assignment into a balanced Int64 ledger; "
                "correct that invalid sentinel value before upgrading"
            )
        operation_id = str(uuid4())
        created_at = datetime.combine(row.month, time.min, tzinfo=timezone.utc)
        bind.execute(operations.insert().values(
            id=operation_id,
            budget_id=row.budget_id,
            occurred_on=row.month,
            kind="assignment",
            actor_user_id=row.owner_user_id,
            note="Migrated monthly assignment",
            source="migration",
            created_at=created_at,
        ))
        bind.execute(postings.insert(), [
            {
                "id": str(uuid4()),
                "operation_id": operation_id,
                "budget_id": row.budget_id,
                "bucket": "ready_to_assign",
                "category_id": None,
                "amount_minor": -row.assigned_minor,
            },
            {
                "id": str(uuid4()),
                "operation_id": operation_id,
                "budget_id": row.budget_id,
                "bucket": "category",
                "category_id": row.category_id,
                "amount_minor": row.assigned_minor,
            },
        ])
        versions[row.budget_id] = versions.get(row.budget_id, 0) + 1
    for budget_id, version in versions.items():
        bind.execute(
            budgets.update().where(budgets.c.id == budget_id).values(allocation_version=version)
        )


def downgrade() -> None:
    op.drop_table("allocation_postings")
    op.drop_table("allocation_operations")
    op.drop_column("budgets", "allocation_version")
