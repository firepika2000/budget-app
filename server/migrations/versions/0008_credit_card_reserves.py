"""Add auditable credit-card payment reserves and system categories."""

from uuid import uuid4

from alembic import op
import sqlalchemy as sa


revision = "0008_credit_reserves"
down_revision = "0007_targets_planning"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.add_column(sa.Column("payment_category_id", sa.String(36), nullable=True))
        batch_op.create_foreign_key(
            "fk_accounts_payment_category_id",
            "categories",
            ["payment_category_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_accounts_payment_category_id", ["payment_category_id"], unique=True)
    op.add_column("categories", sa.Column("system_type", sa.String(30), nullable=True))
    op.add_column("categories", sa.Column("linked_account_id", sa.String(36), nullable=True))
    op.create_index(
        "ix_categories_linked_account_id", "categories", ["linked_account_id"], unique=True
    )
    op.create_table(
        "credit_card_reserve_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("budget_id", sa.String(36), sa.ForeignKey("budgets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("credit_account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("payment_category_id", sa.String(36), sa.ForeignKey("categories.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("source_transaction_id", sa.String(36), sa.ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("transfer_id", sa.String(36), nullable=True),
        sa.Column("occurred_on", sa.Date(), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("amount_minor <> 0", name="ck_credit_reserve_event_nonzero"),
        sa.CheckConstraint(
            "(source_transaction_id IS NOT NULL AND transfer_id IS NULL) OR "
            "(source_transaction_id IS NULL AND transfer_id IS NOT NULL)",
            name="ck_credit_reserve_event_source",
        ),
    )
    for column in (
        "budget_id", "credit_account_id", "payment_category_id", "source_transaction_id",
        "transfer_id", "occurred_on", "actor_user_id",
    ):
        op.create_index(
            f"ix_credit_card_reserve_events_{column}", "credit_card_reserve_events", [column]
        )

    bind = op.get_bind()
    accounts = sa.table(
        "accounts",
        sa.column("id", sa.String),
        sa.column("budget_id", sa.String),
        sa.column("name", sa.String),
        sa.column("account_type", sa.String),
        sa.column("payment_category_id", sa.String),
    )
    groups = sa.table(
        "category_groups",
        sa.column("id", sa.String),
        sa.column("budget_id", sa.String),
        sa.column("name", sa.String),
        sa.column("sort_order", sa.Integer),
    )
    categories = sa.table(
        "categories",
        sa.column("id", sa.String),
        sa.column("budget_id", sa.String),
        sa.column("group_id", sa.String),
        sa.column("name", sa.String),
        sa.column("sort_order", sa.Integer),
        sa.column("is_archived", sa.Boolean),
        sa.column("system_type", sa.String),
        sa.column("linked_account_id", sa.String),
    )
    cards = bind.execute(sa.select(
        accounts.c.id, accounts.c.budget_id, accounts.c.name
    ).where(accounts.c.account_type == "credit")).all()
    group_by_budget: dict[str, str] = {}
    for card in cards:
        group_id = group_by_budget.get(card.budget_id)
        if group_id is None:
            group_id = str(uuid4())
            group_by_budget[card.budget_id] = group_id
            bind.execute(groups.insert().values(
                id=group_id,
                budget_id=card.budget_id,
                name="Credit Card Payments",
                sort_order=-100,
            ))
        category_id = str(uuid4())
        bind.execute(categories.insert().values(
            id=category_id,
            budget_id=card.budget_id,
            group_id=group_id,
            name=f"{card.name} Payment",
            sort_order=0,
            is_archived=False,
            system_type="credit_payment",
            linked_account_id=card.id,
        ))
        bind.execute(accounts.update().where(accounts.c.id == card.id).values(
            payment_category_id=category_id
        ))


def downgrade() -> None:
    op.drop_table("credit_card_reserve_events")
    op.drop_index("ix_categories_linked_account_id", table_name="categories")
    op.drop_column("categories", "linked_account_id")
    op.drop_column("categories", "system_type")
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.drop_index("ix_accounts_payment_category_id")
        batch_op.drop_constraint("fk_accounts_payment_category_id", type_="foreignkey")
        batch_op.drop_column("payment_category_id")
