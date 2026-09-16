"""Add explicit request expiration and system lifecycle actions."""

import sqlalchemy as sa
from alembic import op


revision = "0025_request_lifecycle"
down_revision = "0024_member_lifecycle"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("financial_requests", sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True))
    with op.batch_alter_table("request_actions") as batch:
        batch.alter_column("actor_user_id", existing_type=sa.String(length=36), nullable=True)


def downgrade() -> None:
    with op.batch_alter_table("request_actions") as batch:
        batch.alter_column("actor_user_id", existing_type=sa.String(length=36), nullable=False)
    op.drop_column("financial_requests", "expires_at")
