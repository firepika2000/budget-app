"""Add explicit category resilience classifications."""
import sqlalchemy as sa
from alembic import op

revision = "0036_category_resilience"
down_revision = "0035_schedule_occurrence_limit"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("categories") as batch:
        batch.add_column(sa.Column("is_essential", sa.Boolean(), nullable=False, server_default=sa.false()))
        batch.add_column(sa.Column("is_emergency_fund", sa.Boolean(), nullable=False, server_default=sa.false()))


def downgrade():
    with op.batch_alter_table("categories") as batch:
        batch.drop_column("is_emergency_fund")
        batch.drop_column("is_essential")
