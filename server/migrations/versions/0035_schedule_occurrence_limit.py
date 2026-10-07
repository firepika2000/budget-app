"""Add an optional remaining occurrence limit to recurring schedules."""
import sqlalchemy as sa
from alembic import op

revision = "0035_schedule_occurrence_limit"
down_revision = "0034_schedule_end_date"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.add_column(sa.Column("remaining_occurrences", sa.Integer(), nullable=True))
        batch.create_check_constraint(
            "ck_scheduled_remaining_occurrences_nonnegative",
            "remaining_occurrences IS NULL OR remaining_occurrences >= 0",
        )


def downgrade():
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.drop_constraint("ck_scheduled_remaining_occurrences_nonnegative", type_="check")
        batch.drop_column("remaining_occurrences")
