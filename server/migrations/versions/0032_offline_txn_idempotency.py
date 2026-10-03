"""Add stable identities for idempotent offline transaction replay."""
import sqlalchemy as sa
from alembic import op

revision = "0032_offline_txn_idempotency"
down_revision = "0031_pairing_devices"
branch_labels = None
depends_on = None


def upgrade():
    # Batch mode keeps the same migration valid for the SQLite authority used by local installs
    # and migration verification as well as PostgreSQL-backed QNAP/hosted deployments.
    with op.batch_alter_table("transactions") as batch:
        batch.add_column(sa.Column("client_operation_id", sa.String(36), nullable=True))
        batch.create_unique_constraint(
            "uq_transaction_client_operation",
            ["budget_id", "created_by_user_id", "client_operation_id"],
        )


def downgrade():
    with op.batch_alter_table("transactions") as batch:
        batch.drop_constraint("uq_transaction_client_operation", type_="unique")
        batch.drop_column("client_operation_id")
