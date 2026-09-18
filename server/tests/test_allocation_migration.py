from datetime import datetime, timezone
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text


def migration_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def test_migration_graph_fits_version_table_and_has_one_valid_head():
    scripts = ScriptDirectory.from_config(migration_config())
    revisions = list(scripts.walk_revisions())
    revision_ids = [item.revision for item in revisions]

    assert len(scripts.get_heads()) == 1
    assert len(revision_ids) == len(set(revision_ids))
    assert all(len(revision_id) <= 32 for revision_id in revision_ids)

    known = set(revision_ids)
    for item in revisions:
        parents = item.down_revision
        if parents is None:
            continue
        if isinstance(parents, str):
            parents = (parents,)
        assert set(parents) <= known


def test_database_at_0017_upgrades_to_current_head(tmp_path, monkeypatch):
    database_path = tmp_path / "v04-to-v05.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv(
        "BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters"
    )
    config = migration_config()
    command.upgrade(config, "0017_category_name_uniqueness")
    engine = create_engine(database_url)
    with engine.connect() as connection:
        version = connection.execute(
            text("SELECT version_num FROM alembic_version")
        ).scalar_one()
        assert version == "0017_category_name_uniqueness"

    command.upgrade(config, "head")

    with engine.connect() as connection:
        version = connection.execute(
            text("SELECT version_num FROM alembic_version")
        ).scalar_one()
        attachment_count = connection.execute(
            text("SELECT COUNT(*) FROM transaction_attachments")
        ).scalar_one()
        report_indexes = {row[1] for row in connection.execute(text("PRAGMA index_list('transactions')"))}
        favorite_columns = {row[1] for row in connection.execute(text("PRAGMA table_info('category_favorites')"))}
        debt_term_columns = {row[1] for row in connection.execute(text("PRAGMA table_info('account_debt_terms')"))}
        transaction_columns = {row[1] for row in connection.execute(text("PRAGMA table_info('transactions')"))}
        assert version == "0028_target_snoozes"
        assert attachment_count == 0
        assert "ix_transaction_budget_date_id" in report_indexes
        assert {"budget_id", "user_id", "category_id", "sort_order"} <= favorite_columns
        assert {"account_id", "budget_id", "terms_type", "annual_rate_basis_points"} <= debt_term_columns
        assert "financial_classification" in transaction_columns


def test_0026_debt_terms_populated_upgrade_and_downgrade_preserve_accounts(tmp_path, monkeypatch):
    database_path = tmp_path / "debt-terms.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0025_request_lifecycle")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES ('u1', 'owner@example.com', 'Owner', 'hash', :now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id, name, owner_user_id, created_at) VALUES ('h1', 'Home', 'u1', :now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES ('b1', 'h1', 'Budget', 'USD', 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES ('a1', 'b1', 'Loan', 'loan', 0, 0, :now)"), {"now": now})

    command.upgrade(config, "head")
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO account_debt_terms (account_id, budget_id, terms_type, annual_rate_basis_points, updated_at) "
            "VALUES ('a1', 'b1', 'installment_loan', 625, :now)"
        ), {"now": now})
        assert connection.execute(text("SELECT annual_rate_basis_points FROM account_debt_terms WHERE account_id = 'a1'")).scalar_one() == 625

    command.downgrade(config, "0025_request_lifecycle")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT name FROM accounts WHERE id = 'a1'")).scalar_one() == "Loan"
        assert "account_debt_terms" not in {
            row[0] for row in connection.execute(text("SELECT name FROM sqlite_master WHERE type = 'table'"))
        }


def test_0027_interest_classification_preserves_populated_history(tmp_path, monkeypatch):
    database_path = tmp_path / "interest-classification.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0026_debt_terms")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES ('u-interest', 'history@example.com', 'History', 'hash', :now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id, name, owner_user_id, created_at) VALUES ('h-interest', 'History', 'u-interest', :now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES ('b-interest', 'h-interest', 'Budget', 'USD', 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES ('a-interest', 'b-interest', 'Card', 'credit', 1, 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO transactions (id, budget_id, account_id, amount_minor, occurred_on, payee_name, memo, is_cleared, is_reconciled, tags, attachment_metadata, status, created_by_user_id, created_at) VALUES ('t-interest', 'b-interest', 'a-interest', -1234, '2026-08-01', 'Legacy issuer', '', 1, 0, '[]', '[]', 'posted', 'u-interest', :now)"), {"now": now})
    command.upgrade(config, "head")
    with engine.connect() as connection:
        row = connection.execute(text("SELECT amount_minor, financial_classification FROM transactions WHERE id='t-interest'")).one()
        assert row == (-1234, None)
        assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0028_target_snoozes"
    command.downgrade(config, "0026_debt_terms")
    with engine.connect() as connection:
        assert connection.execute(text("SELECT amount_minor FROM transactions WHERE id='t-interest'")).scalar_one() == -1234


def test_0028_snooze_upgrade_downgrade_preserves_populated_financial_rows(tmp_path, monkeypatch):
    database_url = f"sqlite:///{tmp_path / 'target-snooze.db'}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0027_interest_class")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES ('u-snooze', 'snooze@example.com', 'Owner', 'hash', :now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id, name, owner_user_id, created_at) VALUES ('h-snooze', 'Home', 'u-snooze', :now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES ('b-snooze', 'h-snooze', 'Budget', 'USD', 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES ('a-snooze', 'b-snooze', 'Checking', 'checking', 1, 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO transactions (id, budget_id, account_id, amount_minor, occurred_on, payee_name, memo, is_cleared, is_reconciled, tags, attachment_metadata, status, created_by_user_id, created_at) VALUES ('t-snooze', 'b-snooze', 'a-snooze', -2345, '2026-09-01', 'Merchant', 'Keep unchanged', 1, 1, '[]', '[]', 'posted', 'u-snooze', :now)"), {"now": now})
        before = {table: connection.execute(text(f"SELECT * FROM {table}")).all()
                  for table in ("accounts", "transactions", "budgets", "allocation_operations", "allocation_postings")}
    for revision in ("head", "0027_interest_class", "head"):
        if revision == "head":
            command.upgrade(config, revision)
        else:
            command.downgrade(config, revision)
        with engine.connect() as connection:
            for table, rows in before.items():
                assert connection.execute(text(f"SELECT * FROM {table}")).all() == rows
            if revision == "head":
                assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0028_target_snoozes"
                assert connection.execute(text("SELECT COUNT(*) FROM category_target_snoozes")).scalar_one() == 0


def test_0020_repairs_text_only_transaction_payee_identity(tmp_path, monkeypatch):
    database_path = tmp_path / "payee-repair.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0019_txn_rev_attach")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES ('u1', 'owner@example.com', 'Owner', 'hash', :now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id, name, owner_user_id, created_at) VALUES ('h1', 'Home', 'u1', :now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES ('b1', 'h1', 'Budget', 'USD', 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES ('a1', 'b1', 'Checking', 'checking', 1, 0, :now)"), {"now": now})
        connection.execute(text(
            "INSERT INTO transactions (id, budget_id, account_id, category_id, transfer_id, scheduled_transaction_id, payee_id, amount_minor, occurred_on, payee_name, memo, is_cleared, is_reconciled, flag, tags, attachment_metadata, status, created_by_user_id, created_at) "
            "VALUES ('t1', 'b1', 'a1', NULL, NULL, NULL, NULL, -200, '2026-09-15', 'Metadata test', '', 1, 0, 'orange', '[]', '[]', 'posted', 'u1', :now)"
        ), {"now": now})
    command.upgrade(config, "head")
    with engine.connect() as connection:
        row = connection.execute(text("SELECT payee_id, payee_name, amount_minor, flag FROM transactions WHERE id = 't1'")).mappings().one()
        assert row["payee_id"] is not None
        assert {"payee_name": row["payee_name"], "amount_minor": row["amount_minor"], "flag": row["flag"]} == {"payee_name": "Metadata test", "amount_minor": -200, "flag": "orange"}
        payee = connection.execute(text("SELECT display_name, name_key FROM payees WHERE id = :id"), {"id": row["payee_id"]}).mappings().one()
        assert payee == {"display_name": "Metadata test", "name_key": "metadata test"}


def test_0021_links_existing_schedules_without_creating_or_merging_payees(tmp_path, monkeypatch):
    database_path = tmp_path / "scheduled-payee.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv("BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters")
    config = migration_config()
    command.upgrade(config, "0020_payee_identity_repair")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES ('u1', 'owner@example.com', 'Owner', 'hash', :now)"), {"now": now})
        connection.execute(text("INSERT INTO households (id, name, owner_user_id, created_at) VALUES ('h1', 'Home', 'u1', :now)"), {"now": now})
        connection.execute(text("INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) VALUES ('b1', 'h1', 'Budget', 'USD', 0, :now)"), {"now": now})
        connection.execute(text("INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES ('a1', 'b1', 'Checking', 'checking', 1, 0, :now)"), {"now": now})
        connection.execute(text(
            "INSERT INTO payees (id, household_id, display_name, name_key, is_archived, merged_into_payee_id, created_by_user_id, created_at, updated_at) "
            "VALUES ('p1', 'h1', 'Corner Market', 'corner market', 0, NULL, 'u1', :now, :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO scheduled_transactions (id, budget_id, account_id, destination_account_id, category_id, name, amount_minor, next_date, recurrence_unit, interval_count, memo, is_active, last_realized_on, created_by_user_id, created_at, updated_at) "
            "VALUES ('s1', 'b1', 'a1', NULL, NULL, '  CORNER   MARKET ', -500, '2026-10-01', 'months', 1, '', 1, NULL, 'u1', :now, :now), "
            "('s2', 'b1', 'a1', NULL, NULL, 'Unknown Merchant', -600, '2026-10-01', 'months', 1, '', 1, NULL, 'u1', :now, :now)"
        ), {"now": now})
    command.upgrade(config, "head")
    with engine.connect() as connection:
        rows = connection.execute(text(
            "SELECT id, payee_id, name, amount_minor FROM scheduled_transactions ORDER BY id"
        )).mappings().all()
        assert rows == [
            {"id": "s1", "payee_id": "p1", "name": "  CORNER   MARKET ", "amount_minor": -500},
            {"id": "s2", "payee_id": None, "name": "Unknown Merchant", "amount_minor": -600},
        ]
        assert connection.execute(text("SELECT COUNT(*) FROM payees")).scalar_one() == 1


def test_existing_monthly_assignment_is_backfilled_into_balanced_ledger(
    tmp_path, monkeypatch
):
    database_path = tmp_path / "migration.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv(
        "BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters"
    )
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0005_refresh_sessions")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO users (id, email, display_name, password_hash, created_at) "
            "VALUES ('user-1', 'owner@example.com', 'Owner', 'hash', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO households (id, name, owner_user_id, created_at) "
            "VALUES ('household-1', 'Home', 'user-1', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO budgets (id, household_id, name, currency_code, created_at) "
            "VALUES ('budget-1', 'household-1', 'Family', 'USD', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO category_groups (id, budget_id, name, sort_order) "
            "VALUES ('group-1', 'budget-1', 'Needs', 0)"
        ))
        connection.execute(text(
            "INSERT INTO categories (id, budget_id, group_id, name, sort_order, is_archived) "
            "VALUES ('category-1', 'budget-1', 'group-1', 'Rent', 0, 0)"
        ))
        connection.execute(text(
            "INSERT INTO monthly_assignments "
            "(id, budget_id, category_id, month, assigned_minor) "
            "VALUES ('assignment-1', 'budget-1', 'category-1', '2026-09-01', 125000)"
        ))

    command.upgrade(config, "head")

    with engine.connect() as connection:
        operation = connection.execute(text(
            "SELECT kind, actor_user_id, source FROM allocation_operations"
        )).mappings().one()
        postings = connection.execute(text(
            "SELECT bucket, category_id, amount_minor FROM allocation_postings "
            "ORDER BY bucket"
        )).mappings().all()
        version = connection.execute(text(
            "SELECT allocation_version FROM budgets WHERE id = 'budget-1'"
        )).scalar_one()
        legacy_amount = connection.execute(text(
            "SELECT assigned_minor FROM monthly_assignments WHERE id = 'assignment-1'"
        )).scalar_one()

    assert operation == {
        "kind": "assignment",
        "actor_user_id": "user-1",
        "source": "migration",
    }
    assert sum(item["amount_minor"] for item in postings) == 0
    assert {item["amount_minor"] for item in postings} == {-125000, 125000}
    assert version == 1
    assert legacy_amount == 125000


def test_existing_credit_account_receives_payment_category(tmp_path, monkeypatch):
    database_path = tmp_path / "credit-migration.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv(
        "BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters"
    )
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "0007_targets_planning")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO users (id, email, display_name, password_hash, created_at) "
            "VALUES ('user-1', 'owner@example.com', 'Owner', 'hash', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO households (id, name, owner_user_id, created_at) "
            "VALUES ('household-1', 'Home', 'user-1', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO budgets "
            "(id, household_id, name, currency_code, allocation_version, created_at) "
            "VALUES ('budget-1', 'household-1', 'Family', 'USD', 0, :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO accounts "
            "(id, budget_id, name, account_type, is_on_budget, is_closed, created_at) "
            "VALUES ('card-1', 'budget-1', 'Visa', 'credit', 1, 0, :now)"
        ), {"now": now})

    command.upgrade(config, "head")

    with engine.connect() as connection:
        payment_category_id = connection.execute(text(
            "SELECT payment_category_id FROM accounts WHERE id = 'card-1'"
        )).scalar_one()
        category = connection.execute(text(
            "SELECT name, system_type, linked_account_id FROM categories WHERE id = :id"
        ), {"id": payment_category_id}).mappings().one()
    assert category == {
        "name": "Visa Payment",
        "system_type": "credit_payment",
        "linked_account_id": "card-1",
    }


def test_populated_v030_database_upgrades_to_current_revision_without_data_loss(
    tmp_path, monkeypatch
):
    database_path = tmp_path / "v030.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("BUDGET_APP_DATABASE_URL", database_url)
    monkeypatch.setenv(
        "BUDGET_APP_JWT_SECRET", "migration-test-secret-that-is-longer-than-32-characters"
    )
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    # Start at the last v0.3-era revision, before any v0.4 delegated/metadata work.
    command.upgrade(config, "0011_credit_attribution")
    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES "
            "('user-1', 'owner@example.com', 'Owner', 'hash', :now), "
            "('user-2', 'teen@example.com', 'Teen', 'hash', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO households (id, name, owner_user_id, created_at) "
            "VALUES ('household-1', 'Home', 'user-1', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO memberships (id, household_id, user_id, role, is_active, authorization_version) VALUES "
            "('m-1', 'household-1', 'user-1', 'owner', 1, 0), "
            "('m-2', 'household-1', 'user-2', 'teen', 1, 0)"
        ))
        connection.execute(text(
            "INSERT INTO budgets (id, household_id, name, currency_code, allocation_version, created_at) "
            "VALUES ('budget-1', 'household-1', 'Family', 'USD', 1, :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO accounts (id, budget_id, name, account_type, is_on_budget, is_closed, created_at) VALUES "
            "('checking', 'budget-1', 'Checking', 'checking', 1, 0, :now), "
            "('visa', 'budget-1', 'Visa', 'credit', 1, 0, :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO category_groups (id, budget_id, name, sort_order) "
            "VALUES ('group-1', 'budget-1', 'Needs', 0)"
        ))
        connection.execute(text(
            "INSERT INTO categories (id, budget_id, group_id, name, sort_order, is_archived) "
            "VALUES ('cat-rent', 'budget-1', 'group-1', 'Rent', 0, 0)"
        ))
        connection.execute(text(
            "INSERT INTO allocation_operations (id, budget_id, occurred_on, kind, actor_user_id, note, source, created_at) "
            "VALUES ('op-1', 'budget-1', '2026-09-01', 'assignment', 'user-1', '', 'manual', :now)"
        ), {"now": now})
        connection.execute(text(
            "INSERT INTO allocation_postings (id, operation_id, budget_id, bucket, category_id, amount_minor) VALUES "
            "('p-1', 'op-1', 'budget-1', 'ready_to_assign', NULL, -125000), "
            "('p-2', 'op-1', 'budget-1', 'category', 'cat-rent', 125000)"
        ))
        connection.execute(text(
            "INSERT INTO transactions "
            "(id, budget_id, account_id, category_id, amount_minor, occurred_on, payee_name, memo, is_cleared, created_by_user_id, created_at) "
            "VALUES ('txn-1', 'budget-1', 'checking', NULL, 500000, '2026-09-02', 'Payroll', '', 1, 'user-1', :now)"
        ), {"now": now})

    command.upgrade(config, "head")

    with engine.connect() as connection:
        assert connection.execute(text("SELECT COUNT(*) FROM households")).scalar_one() == 1
        assert connection.execute(text("SELECT COUNT(*) FROM users")).scalar_one() == 2
        assert connection.execute(text("SELECT COUNT(*) FROM memberships")).scalar_one() == 2
        assert connection.execute(text("SELECT COUNT(*) FROM accounts")).scalar_one() == 2
        assert connection.execute(text("SELECT COUNT(*) FROM categories")).scalar_one() == 1
        assert connection.execute(text("SELECT COUNT(*) FROM transactions")).scalar_one() == 1
        postings = connection.execute(text(
            "SELECT amount_minor FROM allocation_postings"
        )).scalars().all()
        assert sum(postings) == 0
        assert set(postings) == {-125000, 125000}
        # No delegated authority may be invented by the migration.
        assert connection.execute(text("SELECT COUNT(*) FROM delegated_budget_policies")).scalar_one() == 0
        assert connection.execute(text("SELECT COUNT(*) FROM delegated_category_rules")).scalar_one() == 0
        # Immutable-history table exists and starts empty for pre-existing data.
        assert connection.execute(text("SELECT COUNT(*) FROM transaction_changes")).scalar_one() == 0
        # New v0.4 transaction metadata columns initialize safely for existing rows.
        row = connection.execute(text(
            "SELECT flag, tags, attachment_metadata, payee_id, amount_minor FROM transactions WHERE id = 'txn-1'"
        )).mappings().one()
        assert row["flag"] is None
        assert row["tags"] == "[]"
        assert row["attachment_metadata"] == "[]"
        assert row["amount_minor"] == 500000
        assert row["payee_id"] is not None
        payee = connection.execute(text(
            "SELECT household_id, display_name, name_key, is_archived, merged_into_payee_id "
            "FROM payees WHERE id = :id"
        ), {"id": row["payee_id"]}).mappings().one()
        assert payee == {
            "household_id": "household-1", "display_name": "Payroll", "name_key": "payroll",
            "is_archived": 0, "merged_into_payee_id": None,
        }
