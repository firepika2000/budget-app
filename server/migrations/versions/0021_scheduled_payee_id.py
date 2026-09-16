"""Link scheduled transactions to stable first-class payee identities."""

import unicodedata

from alembic import op
import sqlalchemy as sa


revision = "0021_scheduled_payee_id"
down_revision = "0020_payee_identity_repair"
branch_labels = None
depends_on = None


def _key(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).strip().split()).casefold()


def upgrade() -> None:
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.add_column(sa.Column("payee_id", sa.String(36), nullable=True))
        batch.create_foreign_key(
            "fk_scheduled_transactions_payee_id",
            "payees",
            ["payee_id"],
            ["id"],
            ondelete="SET NULL",
        )
    op.create_index(
        "ix_scheduled_transactions_payee_id",
        "scheduled_transactions",
        ["payee_id"],
    )

    connection = op.get_bind()
    payees = connection.execute(sa.text(
        "SELECT id, household_id, name_key FROM payees "
        "WHERE is_archived = :archived AND merged_into_payee_id IS NULL AND name_key IS NOT NULL"
    ), {"archived": False}).mappings().all()
    aliases = connection.execute(sa.text(
        "SELECT p.id, p.household_id, a.name_key FROM payee_aliases a "
        "JOIN payees p ON p.id = a.payee_id "
        "WHERE p.is_archived = :archived AND p.merged_into_payee_id IS NULL"
    ), {"archived": False}).mappings().all()
    by_key = {(row["household_id"], row["name_key"]): row["id"] for row in payees}
    for row in aliases:
        by_key.setdefault((row["household_id"], row["name_key"]), row["id"])

    schedules = connection.execute(sa.text(
        "SELECT s.id, s.name, b.household_id FROM scheduled_transactions s "
        "JOIN budgets b ON b.id = s.budget_id "
        "WHERE s.destination_account_id IS NULL"
    )).mappings().all()
    for row in schedules:
        payee_id = by_key.get((row["household_id"], _key(row["name"])))
        if payee_id is not None:
            connection.execute(sa.text(
                "UPDATE scheduled_transactions SET payee_id = :payee_id WHERE id = :schedule_id"
            ), {"payee_id": payee_id, "schedule_id": row["id"]})


def downgrade() -> None:
    op.drop_index("ix_scheduled_transactions_payee_id", table_name="scheduled_transactions")
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.drop_constraint("fk_scheduled_transactions_payee_id", type_="foreignkey")
        batch.drop_column("payee_id")
