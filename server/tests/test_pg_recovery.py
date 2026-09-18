"""Real PostgreSQL dump/restore proof; never targets an existing destination database."""
import getpass
import hashlib
import os
import shutil
import subprocess
import uuid

from cryptography.exceptions import InvalidTag
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.attachment_storage import AttachmentStorage
from app.config import Settings
from app.database import Base
from app.main import create_app
from app.models import TransactionAttachment
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_pg_concurrency import PG_URL, pg, pg_migrated, pytestmark  # shared isolated PG fixtures


def _connection_environment(url):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    environment.update(PGDATABASE=url.database, PGUSER=url.username or getpass.getuser())
    if url.password:
        environment["PGPASSWORD"] = url.password
    for key, value in (("PGHOST", url.query.get("host") or url.host), ("PGPORT", url.query.get("port") or url.port)):
        if value:
            environment[key] = str(value)
    return environment


def _rows(engine):
    with engine.connect() as connection:
        return {
            table.name: sorted((tuple(row) for row in connection.execute(select(table))), key=repr)
            for table in Base.metadata.sorted_tables
        }


def test_real_dump_restore_preserves_rows_finances_and_encrypted_attachments(pg, tmp_path):
    if not shutil.which("pg_dump") or not shutil.which("pg_restore"):
        pytest.skip("PostgreSQL client tools are required for real dump/restore proof")
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, category = create_budget_structure(pg.client, pg.token, budget["id"])
    record(pg.client, pg.token, budget["id"], account_id=account["id"], amount_minor=100_000, payee_name="Payroll", is_cleared=True)
    purchase = record(pg.client, pg.token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2345, payee_name="Recovery merchant", memo="Preserve this memo", is_cleared=True)
    root = f"/api/v1/budgets/{budget['id']}"
    assigned = pg.client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(pg.token), json={"month": "2026-09-01", "assigned_minor": 10_000, "expected_allocation_version": 0})
    assert assigned.status_code == 200, assigned.text
    card = create_credit_card(pg.client, pg.token, budget["id"])
    record(pg.client, pg.token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-1200, payee_name="Card merchant")
    terms = pg.client.put(f"{root}/accounts/{card['id']}/debt-terms", headers=auth(pg.token), json={"terms_type": "credit_card", "annual_rate_basis_points": 1999})
    assert terms.status_code == 200, terms.text
    savings = pg.client.post(f"{root}/accounts", headers=auth(pg.token), json={"name": "Savings", "account_type": "savings", "is_on_budget": True})
    assert savings.status_code == 201, savings.text
    transfer = pg.client.post(f"{root}/transfers", headers=auth(pg.token), json={"source_account_id": account["id"], "destination_account_id": savings.json()["id"], "amount_minor": 1000, "occurred_on": "2026-09-04", "is_cleared": False})
    assert transfer.status_code == 201, transfer.text
    reconciliation = pg.client.post(f"{root}/accounts/{account['id']}/reconcile", headers=auth(pg.token), json={"statement_balance_minor": 97_655, "through_date": "2026-09-30"})
    assert reconciliation.status_code == 200, reconciliation.text
    schedule = pg.client.post(f"{root}/scheduled-transactions", headers=auth(pg.token), json={"account_id": account["id"], "category_id": category["id"], "name": "Recovery schedule", "amount_minor": -2000, "next_date": "2026-10-01", "recurrence_unit": "months", "interval_count": 1})
    assert schedule.status_code == 201, schedule.text
    add_member(pg.factory, pg.client, "view", budget["id"])
    attachment_url = f"{root}/transactions/{purchase['id']}/attachments"
    content = b"%PDF-1.7\nrecovery integrity fixture"
    uploaded = pg.client.post(attachment_url, headers={**auth(pg.token), "X-Attachment-Filename": "receipt.pdf", "X-Attachment-Content-Type": "application/pdf", "Content-Type": "application/octet-stream"}, content=content)
    assert uploaded.status_code == 201, uploaded.text
    attachment = uploaded.json()
    paths = [f"{root}/accounts/{account['id']}/balance", f"{root}/accounts/{card['id']}/balance", f"{root}/accounts/{card['id']}/debt-terms", f"{root}/months/2026-09-01", f"{root}/transactions", f"{root}/payees", f"{root}/scheduled-transactions"]
    observations = {}
    for path in paths:
        response = pg.client.get(path, headers=auth(pg.token))
        assert response.status_code == 200, response.text
        observations[path] = response.json()
    expected = _rows(pg.engine)
    source_url = make_url(PG_URL)
    destination_name = "budget_recovery_" + uuid.uuid4().hex
    destination_url = source_url.set(database=destination_name)
    environment = _connection_environment(source_url)
    dump = tmp_path / "database.dump"
    subprocess.run(["pg_dump", "--format=custom", "--no-owner", "--no-privileges", "--file", str(dump)], env=environment, check=True, capture_output=True)
    source_settings = pg.client.app.state.settings
    restored_objects = tmp_path / "restored-objects"
    shutil.copytree(source_settings.attachment_storage_path, restored_objects)
    # The destination name is generated here, never derived from human configuration.
    with pg.engine.connect().execution_options(isolation_level="AUTOCOMMIT") as connection:
        connection.execute(text(f'CREATE DATABASE "{destination_name}"'))
    restored_engine = create_engine(destination_url)
    try:
        environment["PGDATABASE"] = destination_name
        subprocess.run(["pg_restore", "--exit-on-error", "--single-transaction", "--no-owner", "--no-privileges", "--dbname", destination_name, str(dump)], env=environment, check=True, capture_output=True)
        assert _rows(restored_engine) == expected
        with restored_engine.connect() as connection:
            assert connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0027_interest_class"
        restored_app = create_app(Settings(database_url=destination_url.render_as_string(hide_password=False), jwt_secret=source_settings.jwt_secret, attachment_storage_path=str(restored_objects)))
        restored_app.state.session_factory = sessionmaker(bind=restored_engine, expire_on_commit=False)
        with TestClient(restored_app) as client:
            for path, expected_observation in observations.items():
                response = client.get(path, headers=auth(pg.token))
                assert response.status_code == 200, response.text
                assert response.json() == expected_observation
            response = client.get(f"{attachment_url}/{attachment['id']}", headers=auth(pg.token))
            assert response.status_code == 200
            assert response.content == content
            assert hashlib.sha256(response.content).hexdigest() == attachment["sha256"]
        with pg.factory() as session:
            storage_key = session.get(TransactionAttachment, attachment["id"]).storage_key
        ciphertext = (restored_objects / storage_key).read_bytes()
        assert content not in ciphertext
        with pytest.raises(InvalidTag):
            AttachmentStorage(str(restored_objects), "wrong-key").read(storage_key)
        (restored_objects / storage_key).write_bytes(ciphertext[:-1] + bytes([ciphertext[-1] ^ 1]))
        with pytest.raises(InvalidTag):
            AttachmentStorage(str(restored_objects), source_settings.jwt_secret).read(storage_key)
        # Corruption testing touched only the restored copy, never the source objects.
        assert AttachmentStorage(source_settings.attachment_storage_path, source_settings.jwt_secret).read(storage_key) == content
    finally:
        restored_engine.dispose()
        with pg.engine.connect().execution_options(isolation_level="AUTOCOMMIT") as connection:
            connection.execute(text(f'DROP DATABASE "{destination_name}"'))
