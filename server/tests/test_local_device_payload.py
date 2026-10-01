from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path
import sqlite3

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from scripts.local_device_payload import _id, convert_staged_local_device
from scripts.local_device_transfer import (
    canonical_json, import_local_device_backup_into_server, LOCAL_APPLICATION_ID,
)
from scripts.local_server import LocalServerConfiguration, migrate
from scripts.portable_import import import_payload
from .test_local_device_transfer import _encoded, _encrypted_payload


SERVER_ROOT = Path(__file__).parents[1]


def _authority(root: Path) -> Path:
    root.mkdir()
    database_path = root / "authority.sqlite3"
    schema = f"""
    PRAGMA application_id={LOCAL_APPLICATION_ID};
    PRAGMA user_version=5;
    CREATE TABLE households(id TEXT,name TEXT,created_at TEXT);
    CREATE TABLE users(id TEXT,display_name TEXT,email TEXT);
    CREATE TABLE memberships(household_id TEXT,user_id TEXT,role TEXT,is_active INTEGER);
    CREATE TABLE budgets(id TEXT,household_id TEXT,name TEXT,currency_code TEXT,cash_rollover_policy TEXT,created_at TEXT);
    CREATE TABLE accounts(id TEXT,budget_id TEXT,name TEXT,kind TEXT,is_on_budget INTEGER,is_closed INTEGER,opening_balance_minor INTEGER,created_at TEXT);
    CREATE TABLE category_groups(id TEXT,budget_id TEXT,name TEXT,sort_order INTEGER,is_archived INTEGER);
    CREATE TABLE categories(id TEXT,budget_id TEXT,group_id TEXT,name TEXT,delegated_user_id TEXT,is_archived INTEGER,sort_order INTEGER,is_favorite INTEGER,favorite_sort_order INTEGER);
    CREATE TABLE payees(id TEXT,budget_id TEXT,name TEXT,normalized_name TEXT,default_category_id TEXT,is_archived INTEGER);
    CREATE TABLE payee_aliases(id TEXT,payee_id TEXT,display_name TEXT,normalized_name TEXT);
    CREATE TABLE transactions(id TEXT,budget_id TEXT,account_id TEXT,payee_id TEXT,amount_minor INTEGER,occurred_on TEXT,memo TEXT,is_cleared INTEGER,is_reconciled INTEGER,status TEXT,transfer_id TEXT,created_by_user_id TEXT,created_at TEXT,payee_name TEXT,flag TEXT,tags_json TEXT,financial_classification TEXT,void_reason TEXT,reversal_of_transaction_id TEXT,reversal_transaction_id TEXT);
    CREATE TABLE transaction_splits(id TEXT,transaction_id TEXT,category_id TEXT,amount_minor INTEGER,memo TEXT);
    CREATE TABLE allocation_operations(id TEXT,budget_id TEXT,category_id TEXT,amount_minor INTEGER,occurred_on TEXT,kind TEXT,actor_user_id TEXT,note TEXT,created_at TEXT,operation_id TEXT,source_category_id TEXT);
    CREATE TABLE reconciliations(id TEXT,account_id TEXT,statement_date TEXT,statement_balance_minor INTEGER,adjustment_transaction_id TEXT,created_at TEXT);
    CREATE TABLE category_targets(category_id TEXT,target_type TEXT,amount_minor INTEGER,cadence TEXT,effective_month TEXT,snoozed_month TEXT,target_date TEXT,recurrence_months INTEGER,minimum_contribution_minor INTEGER,priority INTEGER,is_active INTEGER,snoozed_months_json TEXT);
    CREATE TABLE scheduled_transactions(id TEXT,budget_id TEXT,account_id TEXT,destination_account_id TEXT,category_id TEXT,payee_id TEXT,name TEXT,amount_minor INTEGER,next_date TEXT,recurrence_unit TEXT,interval_count INTEGER,memo TEXT,is_active INTEGER,financial_classification TEXT,last_realized_on TEXT);
    CREATE TABLE attachments(id TEXT,transaction_id TEXT,filename TEXT,content_type TEXT,size_bytes INTEGER,sha256 TEXT,object_name TEXT,created_at TEXT);
    CREATE TABLE account_debt_terms(account_id TEXT,terms_type TEXT,annual_rate_basis_points INTEGER,rate_type TEXT,payment_frequency TEXT,scheduled_payment_minor INTEGER,minimum_payment_rule TEXT,minimum_payment_minor INTEGER,minimum_payment_rate_basis_points INTEGER,due_day INTEGER,statement_day INTEGER,original_principal_minor INTEGER,original_term_months INTEGER,remaining_term_months INTEGER,promotional_rate_basis_points INTEGER,promotional_ends_on TEXT,updated_at TEXT);
    CREATE TABLE cash_rollover_policies(id TEXT,budget_id TEXT,effective_month TEXT,policy TEXT,version INTEGER,source TEXT,actor_user_id TEXT,created_at TEXT);
    CREATE TABLE credit_reserve_attributions(transaction_id TEXT,category_id TEXT,amount_minor INTEGER);
    CREATE TABLE transaction_changes(id TEXT,budget_id TEXT,transaction_id TEXT,actor_user_id TEXT,action TEXT,before_json TEXT,after_json TEXT,created_at TEXT);
    CREATE TABLE credit_reserve_events(id TEXT,budget_id TEXT,credit_account_id TEXT,payment_category_id TEXT,spending_category_id TEXT,source_transaction_id TEXT,transfer_id TEXT,occurred_on TEXT,amount_minor INTEGER,kind TEXT,actor_user_id TEXT,created_at TEXT);
    """
    stamp = "2026-10-01T12:00:00+00:00"
    with sqlite3.connect(database_path) as database:
        database.executescript(schema)
        database.execute("INSERT INTO households VALUES(?,?,?)", ("household", "Phone household", stamp))
        database.execute("INSERT INTO users VALUES(?,?,NULL)", ("owner", "Phone Owner"))
        database.execute("INSERT INTO memberships VALUES(?,?,?,1)", ("household", "owner", "owner"))
        database.execute("INSERT INTO budgets VALUES(?,?,?,?,?,?)", ("budget", "household", "Phone budget", "USD", "carry_category_deficit", stamp))
        database.executemany("INSERT INTO accounts VALUES(?,?,?,?,?,?,?,?)", [
            ("checking", "budget", "Checking", "checking", 1, 0, 10_000, stamp),
            ("card", "budget", "Card", "credit", 1, 0, 0, stamp),
        ])
        database.execute("INSERT INTO category_groups VALUES(?,?,?,?,?)", ("group", "budget", "Needs", 0, 0))
        database.execute("INSERT INTO categories VALUES(?,?,?,?,?,?,?,?,?)", ("groceries", "budget", "group", "Groceries", None, 0, 0, 1, 0))
        database.execute("INSERT INTO payees VALUES(?,?,?,?,?,?)", ("payee", "budget", "Market", "market", "groceries", 0))
        database.execute("INSERT INTO payee_aliases VALUES(?,?,?,?)", ("alias", "payee", "The Market", "the market"))
        database.executemany("INSERT INTO transactions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            ("purchase", "budget", "card", "payee", -5_00, "2026-10-02", "food", 1, 0, "posted", None, "owner", stamp, "Market", "orange", '["weekly"]', None, None, None, None),
            ("payment-out", "budget", "checking", None, -3_00, "2026-10-03", "payment", 1, 0, "posted", "transfer", "owner", stamp, "Transfer", None, "[]", None, None, None, None),
            ("payment-in", "budget", "card", None, 3_00, "2026-10-03", "payment", 1, 0, "posted", "transfer", "owner", stamp, "Transfer", None, "[]", None, None, None, None),
        ])
        database.execute("INSERT INTO transaction_splits VALUES(?,?,?,?,?)", ("split", "purchase", "groceries", -5_00, ""))
        database.execute("INSERT INTO allocation_operations VALUES(?,?,?,?,?,?,?,?,?,?,?)", ("allocation", "budget", "groceries", 10_00, "2026-10-01", "assignment", "owner", "Fund groceries", stamp, "allocation", None))
        database.execute("INSERT INTO reconciliations VALUES(?,?,?,?,?,?)", ("recon", "checking", "2026-10-03", 9_700, None, stamp))
        database.execute("INSERT INTO category_targets VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", ("groceries", "monthly_funding", 20_00, "monthly", "2026-10-01", None, None, None, 0, 50, 1, '["2026-11-01"]'))
        database.execute("INSERT INTO scheduled_transactions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ("schedule", "budget", "checking", None, "groceries", "payee", "Market", -1_00, "2026-11-01", "month", 1, "future", 1, None, None))
        database.execute("INSERT INTO account_debt_terms VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ("card", "credit_card", 1999, "variable", "monthly", None, "fixed", 25_00, None, 15, None, None, None, None, None, None, stamp))
        database.execute("INSERT INTO cash_rollover_policies VALUES(?,?,?,?,?,?,?,?)", ("rollover", "budget", "2026-11-01", "carry_category_deficit", 1, "local", None, stamp))
        database.execute("INSERT INTO credit_reserve_attributions VALUES(?,?,?)", ("purchase", "groceries", 5_00))
        database.execute("INSERT INTO transaction_changes VALUES(?,?,?,?,?,?,?,?)", ("change", "budget", "purchase", "owner", "create", None, '{"amount_minor":-500}', stamp))
        database.execute("INSERT INTO credit_reserve_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", ("reserve", "budget", "card", _id("budget", "credit-payment", "card"), "groceries", "purchase", None, "2026-10-02", 5_00, "funded_purchase", "owner", stamp))
        database.execute("INSERT INTO credit_reserve_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", ("payment-reserve", "budget", "card", _id("budget", "credit-payment", "card"), None, None, "transfer", "2026-10-03", -3_00, "payment", "owner", stamp))

    attachment_key = bytes(range(32))
    (root / "attachment-key.bin").write_bytes(attachment_key)
    content = b"local receipt"
    nonce = bytes(range(12))
    object_root = root / "Attachments" / "objects"
    object_root.mkdir(parents=True)
    (object_root / "receipt.enc").write_bytes(b"BAV1" + nonce + AESGCM(attachment_key).encrypt(nonce, content, None))
    with sqlite3.connect(database_path) as database:
        database.execute("INSERT INTO attachments VALUES(?,?,?,?,?,?,?,?)", (
            "attachment", "purchase", "receipt.jpg", "image/jpeg", len(content),
            hashlib.sha256(content).hexdigest(), "receipt.enc", stamp,
        ))
    return root


def _backup_package(source: Path, package: Path, key: bytes) -> Path:
    payload_root = package / "payload"
    payload_root.mkdir(parents=True)
    values = [
        ("000000.cpenc", "authority.sqlite3", "database", (source / "authority.sqlite3").read_bytes()),
        ("000001.cpenc", "attachment-key.bin", "attachment_key", (source / "attachment-key.bin").read_bytes()),
        ("000002.cpenc", "Attachments/objects/receipt.enc", "attachment_object", (source / "Attachments" / "objects" / "receipt.enc").read_bytes()),
    ]
    files = []
    for payload_name, restore_path, role, plaintext in values:
        encrypted, observation = _encrypted_payload(plaintext, key)
        (payload_root / payload_name).write_bytes(encrypted)
        files.append({
            "payload_name": payload_name, "restore_path": restore_path, "role": role,
            **observation,
        })
    manifest = {
        "format": "com.clearpocket.local-backup", "version": 1,
        "created_at": "2026-10-01T12:00:00Z", "local_schema_version": 4,
        "budget_id": "budget", "files": files, "authentication": "",
    }
    manifest["authentication"] = hmac.new(key, canonical_json(manifest), hashlib.sha256).hexdigest()
    (package / "manifest.json").write_bytes(canonical_json(manifest))
    return package


def test_verified_local_device_converts_and_imports_complete_exact_authority(tmp_path: Path):
    staged = _authority(tmp_path / "staged")
    legacy_group_id = "group-" + ("g" * 40)
    legacy_transaction_id = "transaction-" + ("t" * 40)
    legacy_split_id = "split-" + ("s" * 40)
    legacy_alias_id = "alias-" + ("a" * 40)
    legacy_attachment_id = "attachment-" + ("x" * 40)
    with sqlite3.connect(staged / "authority.sqlite3") as database:
        database.execute("UPDATE category_groups SET id=? WHERE id='group'", (legacy_group_id,))
        database.execute("UPDATE categories SET group_id=? WHERE group_id='group'", (legacy_group_id,))
        database.execute("UPDATE transactions SET id=? WHERE id='purchase'", (legacy_transaction_id,))
        database.execute("UPDATE transaction_splits SET id=?, transaction_id=? WHERE id='split'", (legacy_split_id, legacy_transaction_id))
        database.execute("UPDATE credit_reserve_attributions SET transaction_id=? WHERE transaction_id='purchase'", (legacy_transaction_id,))
        database.execute("UPDATE transaction_changes SET transaction_id=? WHERE transaction_id='purchase'", (legacy_transaction_id,))
        database.execute("UPDATE credit_reserve_events SET source_transaction_id=? WHERE source_transaction_id='purchase'", (legacy_transaction_id,))
        database.execute("UPDATE attachments SET id=?, transaction_id=? WHERE id='attachment'", (legacy_attachment_id, legacy_transaction_id))
        database.execute("UPDATE payee_aliases SET id=? WHERE id='alias'", (legacy_alias_id,))
    payload, extracted = convert_staged_local_device(staged, "owner@example.com")

    assert payload["user_directory"][0]["email"] == "owner@example.com"
    assert sum(item["amount_minor"] for item in payload["allocation_postings"]) == 0
    assert {item["kind"] for item in payload["credit_card_reserve_events"]} == {"funded_purchase", "payment"}
    card = next(item for item in payload["accounts"] if item["id"] == "card")
    assert card["payment_category_id"]
    assert next(item for item in payload["categories"] if item["id"] == card["payment_category_id"])["system_type"] == "credit_payment"
    assert next(item for item in payload["transactions"] if item["payee_name"] == "Starting Balance")["amount_minor"] == 10_000
    assert all(len(item["id"]) <= 36 for collection in (
        "category_groups", "transactions", "transaction_splits", "payee_aliases", "transaction_attachments",
    ) for item in payload[collection])
    converted_attachment = payload["transaction_attachments"][0]
    assert converted_attachment["transaction_id"] == payload["transaction_splits"][0]["transaction_id"]
    assert payload["transaction_changes"][0]["transaction_id"] == converted_attachment["transaction_id"]
    purchase_reserve = next(
        item for item in payload["credit_card_reserve_events"] if item["source_transaction_id"] is not None
    )
    assert purchase_reserve["source_transaction_id"] == converted_attachment["transaction_id"]
    assert purchase_reserve["payment_category_id"] == card["payment_category_id"]
    assert (extracted / "attachments" / converted_attachment["id"]).read_bytes() == b"local receipt"

    destination = LocalServerConfiguration.load_or_create(tmp_path / "server")
    migrate(destination, SERVER_ROOT)
    import_payload(payload, extracted, destination, "new-owner-password")
    with sqlite3.connect(destination.database_path) as database:
        assert database.execute("SELECT COALESCE(SUM(amount_minor),0) FROM allocation_postings").fetchone() == (0,)
        assert database.execute("SELECT COUNT(*) FROM credit_card_reserve_events").fetchone() == (2,)
        assert database.execute("SELECT action,after_json FROM transaction_changes").fetchone() == (
            "create", '{"amount_minor":-500}'
        )
        assert database.execute("SELECT payment_category_id FROM accounts WHERE id='card'").fetchone()[0]
        assert database.execute("SELECT amount_minor FROM transactions WHERE payee_name='Starting Balance'").fetchone() == (10_000,)
        assert database.execute("PRAGMA foreign_key_check").fetchall() == []


def test_authenticated_backup_initializes_configured_server_and_records_recovery(tmp_path: Path, monkeypatch):
    source = _authority(tmp_path / "source")
    backup_key = bytes(reversed(range(32)))
    package = _backup_package(source, tmp_path / "phone.clearpocketbackup", backup_key)
    destination = LocalServerConfiguration.load_or_create(tmp_path / "configured-server")
    migrate(destination, SERVER_ROOT)
    environment = destination.environment()
    for name, value in environment.items():
        monkeypatch.setenv(name, value)

    manifest = import_local_device_backup_into_server(
        package, _encoded(backup_key), "owner@example.com", "new-owner-password",
    )

    assert manifest["budget_id"] == "budget"
    status = json.loads(destination.recovery_status_path.read_text())
    assert status["source_provider"] == "local_device_backup"
    assert len(status["source_archive_sha256"]) == 64
    with sqlite3.connect(destination.database_path) as database:
        assert database.execute("SELECT email FROM users WHERE id='owner'").fetchone() == ("owner@example.com",)
        assert database.execute("SELECT COUNT(*) FROM credit_card_reserve_events").fetchone() == (2,)
        assert database.execute("PRAGMA foreign_key_check").fetchall() == []
