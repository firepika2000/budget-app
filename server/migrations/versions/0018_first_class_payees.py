"""Add household-owned first-class payees without merging ambiguous legacy names."""

from collections import defaultdict
from datetime import datetime, timezone
from uuid import uuid4

from alembic import op
import sqlalchemy as sa

revision = "0018_first_class_payees"
down_revision = "0017_category_name_uniqueness"
branch_labels = None
depends_on = None

SYSTEM_PAYEES = {"transfer", "starting balance", "reconciliation adjustment"}


def _key(value: str) -> str:
    return value.strip().casefold()


def upgrade() -> None:
    op.create_table(
        "payees",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("household_id", sa.String(36), sa.ForeignKey("households.id", ondelete="CASCADE"), nullable=False),
        sa.Column("display_name", sa.String(150), nullable=False),
        sa.Column("name_key", sa.String(255), nullable=True),
        sa.Column("is_archived", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("merged_into_payee_id", sa.String(36), sa.ForeignKey("payees.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_payees_household_id", "payees", ["household_id"])
    op.create_index("ix_payees_merged_into_payee_id", "payees", ["merged_into_payee_id"])
    op.create_index("ix_payees_created_by_user_id", "payees", ["created_by_user_id"])
    op.create_index("uq_payees_household_name_key", "payees", ["household_id", "name_key"], unique=True)
    op.create_table(
        "payee_aliases",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("payee_id", sa.String(36), sa.ForeignKey("payees.id", ondelete="CASCADE"), nullable=False),
        sa.Column("display_name", sa.String(150), nullable=False),
        sa.Column("name_key", sa.String(255), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_payee_aliases_payee_id", "payee_aliases", ["payee_id"])
    op.create_index("ix_payee_aliases_name_key", "payee_aliases", ["name_key"])
    op.create_index("ix_payee_aliases_created_by_user_id", "payee_aliases", ["created_by_user_id"])
    op.create_table(
        "payee_budget_preferences",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("payee_id", sa.String(36), sa.ForeignKey("payees.id", ondelete="CASCADE"), nullable=False),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("default_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="SET NULL"), nullable=True),
        sa.Column("updated_by_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("payee_id", "budget_id"),
    )
    for column in ("payee_id", "budget_id", "default_category_id", "updated_by_user_id"):
        op.create_index(f"ix_payee_budget_preferences_{column}", "payee_budget_preferences", [column])
    with op.batch_alter_table("transactions") as batch:
        batch.add_column(sa.Column("payee_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_transactions_payee_id", "payees", ["payee_id"], ["id"], ondelete="SET NULL")
    op.create_index("ix_transactions_payee_id", "transactions", ["payee_id"])

    connection = op.get_bind()
    rows = connection.execute(sa.text(
        "SELECT t.id, t.payee_name, t.created_by_user_id, b.household_id "
        "FROM transactions t JOIN budgets b ON b.id = t.budget_id "
        "WHERE trim(t.payee_name) <> ''"
    )).mappings().all()
    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        if _key(row["payee_name"]) not in SYSTEM_PAYEES:
            grouped[(row["household_id"], row["payee_name"].strip())].append(row)
    normalized_counts: dict[tuple[str, str], int] = defaultdict(int)
    for household_id, exact_name in grouped:
        normalized_counts[(household_id, _key(exact_name))] += 1
    now = datetime.now(timezone.utc)
    for (household_id, exact_name), transactions in grouped.items():
        payee_id = str(uuid4())
        name_key = _key(exact_name) if normalized_counts[(household_id, _key(exact_name))] == 1 else None
        connection.execute(sa.text(
            "INSERT INTO payees (id, household_id, display_name, name_key, is_archived, created_by_user_id, created_at, updated_at) "
            "VALUES (:id, :household_id, :display_name, :name_key, :is_archived, :actor, :created_at, :updated_at)"
        ), {"id": payee_id, "household_id": household_id, "display_name": exact_name, "name_key": name_key,
            "is_archived": False, "actor": transactions[0]["created_by_user_id"], "created_at": now, "updated_at": now})
        connection.execute(sa.text("UPDATE transactions SET payee_id = :payee_id WHERE id IN :ids").bindparams(
            sa.bindparam("ids", expanding=True)
        ), {"payee_id": payee_id, "ids": [row["id"] for row in transactions]})


def downgrade() -> None:
    op.drop_index("ix_transactions_payee_id", table_name="transactions")
    with op.batch_alter_table("transactions") as batch:
        batch.drop_constraint("fk_transactions_payee_id", type_="foreignkey")
        batch.drop_column("payee_id")
    op.drop_table("payee_budget_preferences")
    op.drop_table("payee_aliases")
    op.drop_table("payees")
