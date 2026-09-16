"""Repair post-v0.5 textual transactions that missed first-class payee identity."""

from datetime import datetime, timezone
import unicodedata
from uuid import uuid4

from alembic import op
import sqlalchemy as sa

revision = "0020_payee_identity_repair"
down_revision = "0019_txn_rev_attach"
branch_labels = None
depends_on = None

SYSTEM_PAYEES = {"transfer", "starting balance", "reconciliation adjustment"}


def _display(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).strip().split())


def _key(value: str) -> str:
    return _display(value).casefold()


def upgrade() -> None:
    connection = op.get_bind()
    rows = connection.execute(sa.text(
        "SELECT t.id, t.payee_name, t.created_by_user_id, b.household_id "
        "FROM transactions t JOIN budgets b ON b.id = t.budget_id "
        "WHERE t.payee_id IS NULL AND t.transfer_id IS NULL AND trim(t.payee_name) <> '' "
        "AND t.status <> 'reversal'"
    )).mappings().all()
    existing = connection.execute(sa.text(
        "SELECT id, household_id, display_name, name_key FROM payees "
        "WHERE is_archived = :archived AND merged_into_payee_id IS NULL"
    ), {"archived": False}).mappings().all()
    by_key = {(row["household_id"], row["name_key"]): row["id"] for row in existing if row["name_key"]}
    by_exact = {(row["household_id"], row["display_name"]): row["id"] for row in existing}
    aliases = connection.execute(sa.text(
        "SELECT p.household_id, a.name_key, p.id FROM payee_aliases a "
        "JOIN payees p ON p.id = a.payee_id "
        "WHERE p.is_archived = :archived AND p.merged_into_payee_id IS NULL"
    ), {"archived": False}).mappings().all()
    by_alias = {(row["household_id"], row["name_key"]): row["id"] for row in aliases}
    now = datetime.now(timezone.utc)

    for row in rows:
        name = _display(row["payee_name"])
        key = _key(name)
        if key in SYSTEM_PAYEES:
            continue
        lookup = (row["household_id"], key)
        payee_id = by_key.get(lookup) or by_alias.get(lookup) or by_exact.get((row["household_id"], name))
        if payee_id is None:
            payee_id = str(uuid4())
            connection.execute(sa.text(
                "INSERT INTO payees (id, household_id, display_name, name_key, is_archived, "
                "created_by_user_id, created_at, updated_at) VALUES "
                "(:id, :household_id, :display_name, :name_key, :archived, :actor, :created_at, :updated_at)"
            ), {
                "id": payee_id, "household_id": row["household_id"], "display_name": name,
                "name_key": key, "archived": False, "actor": row["created_by_user_id"],
                "created_at": now, "updated_at": now,
            })
            by_key[lookup] = payee_id
        connection.execute(sa.text(
            "UPDATE transactions SET payee_id = :payee_id WHERE id = :transaction_id"
        ), {"payee_id": payee_id, "transaction_id": row["id"]})


def downgrade() -> None:
    # Identity repair is lossless and intentionally retained. Removing links would recreate the defect.
    pass
