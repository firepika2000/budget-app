"""Add an optional final occurrence date to recurring schedules."""
import sqlalchemy as sa
from alembic import op

revision = "0034_schedule_end_date"
down_revision = "0033_category_customization"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.add_column(sa.Column("end_date", sa.Date(), nullable=True))


def downgrade():
    with op.batch_alter_table("scheduled_transactions") as batch:
        batch.drop_column("end_date")
