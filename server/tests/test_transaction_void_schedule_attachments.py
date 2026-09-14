import hashlib
import shutil
from datetime import date, timedelta

from app.models import CreditCardReserveEvent, Transaction, TransactionAttachment, TransactionChange
from app.attachment_storage import AttachmentStorage

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_delegated_access import add_child


def endpoint(budget_id, transaction_id, suffix):
    return f"/api/v1/budgets/{budget_id}/transactions/{transaction_id}/{suffix}"


def test_void_cash_split_is_one_way_current_dated_and_exact(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Wants", "Dining")
    original = record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=-1500,
                      payee_name="Market", splits=[{"category_id": groceries["id"], "amount_minor": -1000},
                                                    {"category_id": dining["id"], "amount_minor": -500}])
    response = client.post(endpoint(budget["id"], original["id"], "void"), headers=auth(owner_token), json={"reason": "Duplicate charge"})
    assert response.status_code == 201, response.text
    reversal = response.json()
    assert reversal["status"] == "reversal"
    assert reversal["amount_minor"] == 1500
    assert reversal["occurred_on"] == date.today().isoformat()
    assert reversal["reversal_of_transaction_id"] == original["id"]
    assert sum(item["amount_minor"] for item in reversal["splits"]) == 1500
    rows = {item["id"]: item for item in client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()}
    assert rows[original["id"]]["status"] == "voided"
    assert rows[original["id"]]["reversal_transaction_id"] == reversal["id"]
    assert rows[original["id"]]["void_reason"] == "Duplicate charge"
    assert client.post(endpoint(budget["id"], original["id"], "void"), headers=auth(owner_token), json={}).status_code == 409
    assert client.put(f"/api/v1/budgets/{budget['id']}/transactions/{original['id']}", headers=auth(owner_token), json={
        "account_id": account["id"], "amount_minor": -1, "occurred_on": date.today().isoformat(),
    }).status_code == 409
    with session_factory() as db:
        assert db.query(TransactionChange).filter_by(transaction_id=original["id"], action="voided").count() == 1


def test_void_funded_card_purchase_exactly_releases_reserve(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=50000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment", headers=auth(owner_token), json={"month": date.today().replace(day=1).isoformat(), "assigned_minor": 10000})
    original = record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-5000, occurred_on=date.today().isoformat())
    assert client.post(endpoint(budget["id"], original["id"], "void"), headers=auth(owner_token), json={}).status_code == 201
    with session_factory() as db:
        events = db.query(CreditCardReserveEvent).filter_by(credit_account_id=card["id"]).all()
        assert len(events) == 2
        assert sum(item.amount_minor for item in events) == 0


def test_void_rejects_reconciled_transfer_and_reversal(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    with session_factory() as db:
        db.get(Transaction, original["id"]).is_reconciled = True
        db.commit()
    assert client.post(endpoint(budget["id"], original["id"], "void"), headers=auth(owner_token), json={}).status_code == 409


def test_void_income_and_categorized_refund_net_exactly(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    income = record(client, owner_token, budget["id"], account_id=account["id"], amount_minor=9000, payee_name="Income", occurred_on=date.today().isoformat())
    refund = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=1200, payee_name="Refund", occurred_on=date.today().isoformat())
    for transaction in (income, refund):
        assert client.post(endpoint(budget["id"], transaction["id"], "void"), headers=auth(owner_token), json={}).status_code == 201
    balance = client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
    assert balance["working_balance_minor"] == 0
    summary = client.get(f"/api/v1/budgets/{budget['id']}/months/{date.today().replace(day=1).isoformat()}", headers=auth(owner_token)).json()
    assert next(item for item in summary["categories"] if item["category_id"] == category["id"])["activity_minor"] == 0


def test_void_unfunded_card_purchase_has_no_phantom_reserve(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=card["id"], category_id=category["id"], amount_minor=-5000, occurred_on=date.today().isoformat())
    assert client.post(endpoint(budget["id"], original["id"], "void"), headers=auth(owner_token), json={}).status_code == 201
    with session_factory() as db:
        assert sum(item.amount_minor for item in db.query(CreditCardReserveEvent).filter_by(credit_account_id=card["id"])) == 0


def test_void_rejects_single_transfer_leg(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    source, _ = create_budget_structure(client, owner_token, budget["id"])
    destination = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={"name": "Savings", "account_type": "savings", "is_on_budget": True}).json()
    transfer = client.post(f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token), json={"source_account_id": source["id"], "destination_account_id": destination["id"], "amount_minor": 100, "occurred_on": date.today().isoformat()}).json()
    leg = transfer["source"]
    assert client.post(endpoint(budget["id"], leg["id"], "void"), headers=auth(owner_token), json={}).status_code == 409


def test_make_recurring_preserves_posting_and_uses_robust_future_calendar(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    original = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-2500,
                      occurred_on="2024-02-29", payee_name="Rent", memo="template")
    before = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    response = client.post(endpoint(budget["id"], original["id"], "schedule"), headers=auth(owner_token), json={"recurrence_unit": "years", "interval_count": 1})
    assert response.status_code == 201, response.text
    schedule = response.json()
    assert date.fromisoformat(schedule["next_date"]) > date.today()
    assert schedule["next_date"].endswith("-02-28")
    assert schedule["amount_minor"] == -2500 and schedule["category_id"] == category["id"]
    assert schedule["memo"] == "template"
    after = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert after == before


def test_encrypted_attachment_round_trip_detach_and_gc(client, owner_token, session_factory, tmp_path):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    content = b"%PDF-1.7\nprivate receipt"
    url = endpoint(budget["id"], transaction["id"], "attachments")
    uploaded = client.post(url, headers={**auth(owner_token), "X-Attachment-Filename": "../receipt.pdf", "X-Attachment-Content-Type": "application/pdf", "Content-Type": "application/octet-stream"}, content=content)
    assert uploaded.status_code == 201, uploaded.text
    attachment = uploaded.json()
    assert attachment["filename"] == "receipt.pdf"
    assert attachment["sha256"] == hashlib.sha256(content).hexdigest()
    with session_factory() as db:
        row = db.get(TransactionAttachment, attachment["id"])
        encrypted = next((tmp_path / "attachments").iterdir()).read_bytes()
        assert content not in encrypted
        assert row.storage_key not in uploaded.text
    downloaded = client.get(f"{url}/{attachment['id']}", headers=auth(owner_token))
    assert downloaded.content == content
    assert downloaded.headers["x-content-sha256"] == attachment["sha256"]
    assert client.delete(f"/api/v1/budgets/{budget['id']}/transactions/{transaction['id']}", headers=auth(owner_token)).status_code == 409
    assert client.delete(f"{url}/{attachment['id']}", headers=auth(owner_token)).status_code == 204
    assert client.get(f"{url}/{attachment['id']}", headers=auth(owner_token)).status_code == 404
    with session_factory() as db:
        row = db.get(TransactionAttachment, attachment["id"])
        row.purge_after = row.detached_at - timedelta(seconds=1)
        db.commit()
    purged = client.post(f"/api/v1/budgets/{budget['id']}/attachments/garbage-collect", headers=auth(owner_token))
    assert purged.json() == {"purged": 1}
    assert not list((tmp_path / "attachments").iterdir())


def test_attachment_rejects_spoofed_or_oversized_content(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    url = endpoint(budget["id"], transaction["id"], "attachments")
    headers = {**auth(owner_token), "X-Attachment-Filename": "fake.pdf", "X-Attachment-Content-Type": "application/pdf", "Content-Type": "application/octet-stream"}
    assert client.post(url, headers=headers, content=b"not a pdf").status_code == 422
    assert client.post(url, headers=headers, content=b"%PDF-" + b"x" * (10 * 1024 * 1024)).status_code == 422


def test_attachment_backup_restore_reconnects_metadata_and_validates_integrity(client, owner_token, session_factory, tmp_path):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    transaction = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
    content = b"\x89PNG\r\n\x1a\nportable attachment"
    url = endpoint(budget["id"], transaction["id"], "attachments")
    uploaded = client.post(url, headers={**auth(owner_token), "X-Attachment-Filename": "receipt.png", "X-Attachment-Content-Type": "image/png", "Content-Type": "application/octet-stream"}, content=content).json()
    with session_factory() as db:
        metadata = db.get(TransactionAttachment, uploaded["id"])
        storage_key = metadata.storage_key
        transaction_id = metadata.transaction_id
    restored_root = tmp_path / "restored-attachments"
    shutil.copytree(tmp_path / "attachments", restored_root)
    restored = AttachmentStorage(str(restored_root), "test-secret-that-is-longer-than-32-characters")
    payload = restored.read(storage_key)
    assert transaction_id == transaction["id"]
    assert hashlib.sha256(payload).hexdigest() == uploaded["sha256"]
    assert payload == content


def test_restricted_member_cannot_discover_hidden_transaction_attachment(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    hidden_account, hidden_category = create_budget_structure(client, owner_token, budget["id"])
    visible_account = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={"name": "Visible", "account_type": "checking", "is_on_budget": True}).json()
    transaction = record(client, owner_token, budget["id"], account_id=hidden_account["id"], category_id=hidden_category["id"], amount_minor=-100)
    url = endpoint(budget["id"], transaction["id"], "attachments")
    uploaded = client.post(url, headers={**auth(owner_token), "X-Attachment-Filename": "receipt.pdf", "X-Attachment-Content-Type": "application/pdf", "Content-Type": "application/octet-stream"}, content=b"%PDF-1.7\nhidden").json()
    child_id, child_token = add_child(session_factory, client)
    client.put(f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token), json={"user_id": child_id, "permission": "contribute"})
    client.put(f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_transactions"], "restrict_accounts": True,
        "account_ids": [visible_account["id"]], "restrict_categories": False, "category_ids": [],
    })
    assert client.get(url, headers=auth(child_token)).status_code == 404
    assert client.get(f"{url}/{uploaded['id']}", headers=auth(child_token)).status_code == 404
