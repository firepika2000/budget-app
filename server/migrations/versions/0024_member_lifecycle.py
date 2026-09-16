"""Add recoverable household-member lifecycle and access audit events."""

import sqlalchemy as sa
from alembic import op


revision = "0024_member_lifecycle"
down_revision = "0023_category_favorites"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("invitations", sa.Column("canceled_at", sa.DateTime(timezone=True), nullable=True))
    op.create_table(
        "household_access_events",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("household_id", sa.String(length=36), nullable=False),
        sa.Column("actor_user_id", sa.String(length=36), nullable=False),
        sa.Column("subject_user_id", sa.String(length=36), nullable=True),
        sa.Column("invitation_id", sa.String(length=36), nullable=True),
        sa.Column("event_type", sa.String(length=40), nullable=False),
        sa.Column("detail", sa.String(length=320), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["household_id"], ["households.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["actor_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["subject_user_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["invitation_id"], ["invitations.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    for column in ("household_id", "actor_user_id", "subject_user_id", "invitation_id"):
        op.create_index(f"ix_household_access_events_{column}", "household_access_events", [column])


def downgrade() -> None:
    op.drop_table("household_access_events")
    op.drop_column("invitations", "canceled_at")
