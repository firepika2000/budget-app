"""Add one-time device pairing and revocable session labels."""
import sqlalchemy as sa
from alembic import op

revision = "0031_pairing_devices"
down_revision = "0030_import_staging"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("refresh_sessions", sa.Column("device_name", sa.String(80), nullable=True))
    op.create_table(
        "pairing_codes",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("redeemed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_pairing_codes_user_id", "pairing_codes", ["user_id"])
    op.create_index("ix_pairing_codes_token_hash", "pairing_codes", ["token_hash"], unique=True)
    op.create_index("ix_pairing_codes_expires_at", "pairing_codes", ["expires_at"])


def downgrade():
    connection = op.get_bind()
    if connection.execute(sa.text("SELECT COUNT(*) FROM pairing_codes")).scalar():
        raise RuntimeError("Cannot remove active pairing records; regenerate or redeem them first")
    if connection.execute(sa.text(
        "SELECT COUNT(*) FROM refresh_sessions WHERE device_name IS NOT NULL"
    )).scalar():
        raise RuntimeError("Cannot remove device labels from populated sessions")
    op.drop_index("ix_pairing_codes_expires_at", table_name="pairing_codes")
    op.drop_index("ix_pairing_codes_token_hash", table_name="pairing_codes")
    op.drop_index("ix_pairing_codes_user_id", table_name="pairing_codes")
    op.drop_table("pairing_codes")
    op.drop_column("refresh_sessions", "device_name")
