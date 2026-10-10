from app.models import ImportBatch, Transaction, User
from sqlalchemy import insert
from datetime import date

from .conftest import auth
from .test_budgeting_api import add_member, create_budget, create_budget_structure


def _stage(client, token, budget_id, account_id, content, **headers):
    base = {
        "Content-Type": "application/octet-stream",
        "X-Statement-Format": "csv",
        "X-Statement-Currency": "USD",
        "X-CSV-Date-Column": "Date",
        "X-CSV-Amount-Column": "Amount",
        "X-CSV-Payee-Column": "Payee",
        "X-CSV-Memo-Column": "Memo",
        "X-Statement-Date-Order": "ymd",
    }
    base.update(headers)
    return client.post(
        f"/api/v1/budgets/{budget_id}/accounts/{account_id}/statement-imports",
        headers={**auth(token), **base}, content=content,
    )


def test_review_excludes_impossible_amount_matches_before_history_limit(client, owner_token, session_factory, monkeypatch):
    from app import import_review
    monkeypatch.setattr(import_review, "MAX_OBSERVATIONS", 100)
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    with session_factory() as db:
        owner = db.query(User).filter_by(email="owner@example.com").one()
        db.execute(insert(Transaction), [
            {"id": f"irrelevant-{i}", "budget_id": budget["id"], "account_id": account["id"],
             "amount_minor": -1, "occurred_on": date(2026, 9, 15), "payee_name": "Other",
             "created_by_user_id": owner.id} for i in range(10000)
        ])
        db.commit()
    response = _stage(client, owner_token, budget["id"], account["id"], b"Date,Amount,Payee,Memo\n2026-09-15,-12.34,Market,statement\n")
    assert response.status_code == 201, response.text
    row = response.json()["candidates"][0]
    assert row["exact_transaction_ids"] == []
    assert row["possible_transaction_ids"] == []
    limited = _stage(client, owner_token, budget["id"], account["id"], b"Date,Amount,Payee,Memo\n2026-09-15,-0.01,Other,statement\n")
    assert limited.status_code == 422, "Relevant histories above the cap must still fail closed"
    with session_factory() as db:
        assert db.query(Transaction).filter_by(budget_id=budget["id"]).count() == 10000
        assert db.query(ImportBatch).filter_by(budget_id=budget["id"]).count() == 1


def test_csv_import_is_money_neutral_and_returns_duplicate_review(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"],
        "amount_minor": -1234, "occurred_on": "2026-09-15",
        "payee_name": "Corner Market", "memo": "existing",
    })
    assert created.status_code == 201
    summary_path = f"/api/v1/budgets/{budget['id']}/months/2026-09-01"
    before = client.get(summary_path, headers=auth(owner_token)).json()

    response = _stage(client, owner_token, budget["id"], account["id"],
                      b"Date,Amount,Payee,Memo\n2026-09-15,-12.34,Corner Market,statement\n")
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["status"] == "review"
    assert body["candidate_count"] == 1
    assert body["candidates"][0]["amount_minor"] == -1234
    assert body["candidates"][0]["exact_transaction_ids"] == [created.json()["id"]]
    assert client.get(summary_path, headers=auth(owner_token)).json() == before
    with session_factory() as db:
        assert db.query(Transaction).count() == 1
        assert db.query(ImportBatch).one().status == "review"

    fetched = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{body['id']}",
        headers=auth(owner_token),
    )
    assert fetched.status_code == 200
    cancelled = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{body['id']}/cancel",
        headers=auth(owner_token), json={"expected_version": 0},
    )
    assert (cancelled.status_code, cancelled.json()["status"], cancelled.json()["version"]) == (200, "cancelled", 1)


def test_csv_import_applies_explicit_comma_decimal_contract(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    response = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date;Amount;Payee;Memo\n2026-09-15;-1.234,56;Market;Grouped export\n",
        **{"X-CSV-Delimiter": ";", "X-CSV-Number-Format": "comma_decimal"},
    )
    assert response.status_code == 201, response.text
    assert response.json()["candidates"][0]["amount_minor"] == -123456

    mismatched = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date;Amount;Payee;Memo\n2026-09-15;-1,234.56;Private;Must not echo\n",
        **{"X-CSV-Delimiter": ";", "X-CSV-Number-Format": "comma_decimal"},
    )
    assert mismatched.status_code == 422
    assert "Private" not in mismatched.text and "Must not echo" not in mismatched.text


def test_import_suggests_visible_first_class_payee_default_without_mutating(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Neighborhood Market", "default_category_id": category["id"],
    })
    assert payee.status_code == 201, payee.text
    alias = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{payee.json()['id']}/aliases",
        headers=auth(owner_token), json={"display_name": "BANK MARKET 4812"},
    )
    assert alias.status_code == 201, alias.text

    before = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()
    staged = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date,Amount,Payee,Memo\n2026-09-15,-12.34,BANK MARKET 4812,Food\n2026-09-16,2.00,Neighborhood Market,Refund\n",
    )
    assert staged.status_code == 201, staged.text
    rows = staged.json()["candidates"]
    assert rows[0]["suggested_category_id"] == category["id"]
    assert rows[1]["suggested_category_id"] is None
    assert client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json() == before
    with session_factory() as db:
        assert db.query(Transaction).count() == 0

    member_token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member_id = db.query(User).filter_by(email="contribute@example.com").one().id
    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token), json={
            "capabilities": ["view_transactions", "create_transaction"],
            "restrict_accounts": True, "account_ids": [account["id"]],
            "restrict_categories": True, "category_ids": [category["id"]],
        },
    )
    assert profile.status_code == 200, profile.text
    restricted = _stage(
        client, member_token, budget["id"], account["id"],
        b"Date,Amount,Payee,Memo\n2026-09-17,-1.00,BANK MARKET 4812,Private-safe\n",
    )
    assert restricted.status_code == 201, restricted.text
    assert restricted.json()["candidates"][0]["suggested_category_id"] is None


def test_import_history_is_bounded_actor_private_and_reopenable(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    first = _stage(client, owner_token, budget["id"], account["id"],
                   b"Date,Amount,Payee,Memo\n2026-09-15,-1.00,Private one,Secret one\n")
    second = _stage(client, owner_token, budget["id"], account["id"],
                    b"Date,Amount,Payee,Memo\n2026-09-16,-2.00,Private two,Secret two\n")
    assert first.status_code == second.status_code == 201

    page = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports?limit=1",
        headers=auth(owner_token),
    )
    assert page.status_code == 200, page.text
    body = page.json()
    assert len(body["items"]) == 1
    assert body["has_more"] is True and body["next_offset"] == 1
    # History intentionally exposes metadata, not imported private text.
    assert "candidates" not in body["items"][0]

    next_page = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports?limit=1&offset=1",
        headers=auth(owner_token),
    )
    assert next_page.status_code == 200
    assert len(next_page.json()["items"]) == 1

    member_token = add_member(session_factory, client, "manage", budget["id"])
    hidden = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports",
        headers=auth(member_token),
    )
    assert hidden.status_code == 200
    assert hidden.json()["items"] == []

    reopened = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{first.json()['id']}",
        headers=auth(owner_token),
    )
    assert reopened.status_code == 200
    assert reopened.json()["candidates"][0]["payee"] == "Private one"


def test_structured_formats_use_the_same_owned_staging_boundary(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    ofx = b"<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260915<TRNAMT>-1.25<NAME>Cafe</STMTTRN></BANKTRANLIST></OFX>"
    response = _stage(client, owner_token, budget["id"], account["id"], ofx,
                      **{"X-Statement-Format": "qfx"})
    assert response.status_code == 201, response.text
    assert response.json()["candidates"][0]["amount_minor"] == -125

    qif = b"!Type:Bank\nD9/16/2026\nT2.50\nPRefund\n^\n"
    response = _stage(client, owner_token, budget["id"], account["id"], qif,
                      **{"X-Statement-Format": "qif", "X-Statement-Date-Order": "mdy"})
    assert response.status_code == 201, response.text
    assert response.json()["candidates"][0]["amount_minor"] == 250

    mt940 = b":20:START\n:61:260917D3,21NTRFNONREF\n:86:Utility Company\n:62F:C260917USD0,00\n"
    response = _stage(client, owner_token, budget["id"], account["id"], mt940,
                      **{"X-Statement-Format": "mt940"})
    assert response.status_code == 201, response.text
    assert response.json()["source_format"] == "mt940"
    assert response.json()["candidates"][0]["amount_minor"] == -321

    camt = b'''<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"><BkToCstmrStmt><Stmt>
      <Ntry><Amt Ccy="USD">4.56</Amt><CdtDbtInd>CRDT</CdtDbtInd><BookgDt><Dt>2026-09-18</Dt></BookgDt>
      <NtryDtls><TxDtls><RltdPties><Dbtr><Pty><Nm>Refund Company</Nm></Pty></Dbtr></RltdPties></TxDtls></NtryDtls></Ntry>
    </Stmt></BkToCstmrStmt></Document>'''
    response = _stage(client, owner_token, budget["id"], account["id"], camt,
                      **{"X-Statement-Format": "camt"})
    assert response.status_code == 201, response.text
    assert response.json()["source_format"] == "camt"
    assert response.json()["candidates"][0]["amount_minor"] == 456


def test_pdf_uses_conservative_review_boundary(client, owner_token, session_factory, monkeypatch):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    monkeypatch.setattr("app.import_formats._extract_pdf_text", lambda _: [
        "09/16/2026 Recognized purchase -4.25", "Balance 100.00",
    ])
    response = _stage(client, owner_token, budget["id"], account["id"], b"%PDF-test",
                      **{"X-Statement-Format": "pdf", "X-Statement-Date-Order": "mdy"})
    assert response.status_code == 201, response.text
    assert response.json()["source_format"] == "pdf"
    assert response.json()["candidates"][0]["amount_minor"] == -425


def test_locally_ocrd_pdf_rows_use_owned_money_neutral_review_boundary(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    summary_path = f"/api/v1/budgets/{budget['id']}/months/2026-09-01"
    before = client.get(summary_path, headers=auth(owner_token)).json()
    response = _stage(
        client, owner_token, budget["id"], account["id"],
        b'date,amount,payee,memo\n"2026-09-16","-4.25","Recognized purchase","Recognized purchase"\n',
        **{
            "X-Statement-Format": "pdf_ocr",
            "X-CSV-Date-Column": "date",
            "X-CSV-Amount-Column": "amount",
            "X-CSV-Payee-Column": "payee",
            "X-CSV-Memo-Column": "memo",
        },
    )
    assert response.status_code == 201, response.text
    assert response.json()["source_format"] == "pdf_ocr"
    assert response.json()["candidates"][0]["amount_minor"] == -425
    assert client.get(summary_path, headers=auth(owner_token)).json() == before
    with session_factory() as db:
        assert db.query(Transaction).count() == 0


def test_import_rejects_wrong_currency_bad_mapping_and_unowned_review(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    csv = b"Date,Amount,Payee\n2026-09-15,-1.00,Private merchant\n"
    wrong = _stage(client, owner_token, budget["id"], account["id"], csv,
                   **{"X-Statement-Currency": "EUR", "X-CSV-Memo-Column": ""})
    assert wrong.status_code == 422
    invalid = _stage(client, owner_token, budget["id"], account["id"], csv,
                     **{"X-CSV-Date-Column": "Missing", "X-CSV-Memo-Column": ""})
    assert invalid.status_code == 422
    good = _stage(client, owner_token, budget["id"], account["id"], csv,
                  **{"X-CSV-Memo-Column": ""})
    # Empty optional header is still an explicitly selected column; omit it instead.
    assert good.status_code == 422
    good = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports",
        headers={**auth(owner_token), "X-Statement-Format": "csv", "X-Statement-Currency": "USD",
                 "Content-Type": "application/octet-stream",
                 "X-CSV-Date-Column": "Date", "X-CSV-Amount-Column": "Amount",
                 "X-CSV-Payee-Column": "Payee"}, content=csv,
    )
    assert good.status_code == 201, good.text
    member_token = add_member(session_factory, client, "manage", budget["id"])
    hidden = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{good.json()['id']}",
        headers=auth(member_token),
    )
    assert hidden.status_code == 404


def test_explicit_approval_posts_selected_rows_once_through_canonical_ledger(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    response = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date,Amount,Payee,Memo\n2026-09-14,-12.34,Market,Food\n2026-09-15,-2.00,Ignored,Skip me\n",
    )
    assert response.status_code == 201, response.text
    batch = response.json()
    approval = {
        "expected_version": batch["version"],
        "items": [
            {"source_row": 2, "action": "post", "category_id": category["id"]},
            {"source_row": 3, "action": "skip"},
        ],
    }
    approved = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/approve",
        headers=auth(owner_token), json=approval,
    )
    assert approved.status_code == 200, approved.text
    body = approved.json()
    assert (body["status"], body["version"]) == ("approved", 1)
    posted = next(row for row in body["candidates"] if row["source_row"] == 2)
    skipped = next(row for row in body["candidates"] if row["source_row"] == 3)
    assert posted["approval_action"] == "post" and posted["posted_transaction_id"]
    assert skipped["approval_action"] == "skip" and skipped["posted_transaction_id"] is None
    with session_factory() as db:
        rows = db.query(Transaction).all()
        assert len(rows) == 1
        assert (rows[0].amount_minor, rows[0].payee_name, rows[0].memo, rows[0].is_cleared) == (-1234, "Market", "Food", True)
        assert rows[0].category_id == category["id"]

    replay = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/approve",
        headers=auth(owner_token), json=approval,
    )
    assert replay.status_code == 409
    with session_factory() as db:
        assert db.query(Transaction).count() == 1


def test_approved_import_undo_is_atomic_auditable_and_versioned(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    batch = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date,Amount,Payee,Memo\n2026-09-14,-12.34,Market,Food\n2026-09-15,-2.00,Cafe,Coffee\n",
    ).json()
    approved = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/approve",
        headers=auth(owner_token), json={"expected_version": batch["version"], "items": [
            {"source_row": 2, "action": "post", "category_id": category["id"]},
            {"source_row": 3, "action": "post", "category_id": category["id"]},
        ]},
    ).json()
    posted_ids = [row["posted_transaction_id"] for row in approved["candidates"]]
    with session_factory() as db:
        db.get(Transaction, posted_ids[1]).is_reconciled = True
        db.commit()
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/undo"
    rejected = client.post(path, headers=auth(owner_token), json={"expected_version": approved["version"]})
    assert rejected.status_code == 409
    with session_factory() as db:
        assert all(db.get(Transaction, transaction_id).status == "posted" for transaction_id in posted_ids)
        db.get(Transaction, posted_ids[1]).is_reconciled = False
        db.commit()

    undone = client.post(path, headers=auth(owner_token), json={"expected_version": approved["version"]})
    assert undone.status_code == 200, undone.text
    assert undone.json()["version"] == approved["version"] + 1
    assert all(row["reversal_transaction_id"] for row in undone.json()["candidates"])
    with session_factory() as db:
        originals = [db.get(Transaction, transaction_id) for transaction_id in posted_ids]
        assert all(item.status == "voided" for item in originals)
        assert db.query(Transaction).filter_by(status="reversal").count() == 2
        assert sum(item.amount_minor for item in db.query(Transaction).all()) == 0
    assert client.post(path, headers=auth(owner_token), json={"expected_version": approved["version"]}).status_code == 409


def test_approval_requires_complete_review_and_rolls_back_failed_canonical_post(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    response = _stage(
        client, owner_token, budget["id"], account["id"],
        b"Date,Amount,Payee,Memo\n2099-09-14,-12.34,Future,Invalid post\n2026-09-15,-2.00,Other,Review\n",
    )
    batch = response.json()
    incomplete = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/approve",
        headers=auth(owner_token), json={"expected_version": 0, "items": [{"source_row": 2, "action": "skip"}]},
    )
    assert incomplete.status_code == 422
    failed = client.post(
        f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/statement-imports/{batch['id']}/approve",
        headers=auth(owner_token), json={"expected_version": 0, "items": [
            {"source_row": 2, "action": "post"}, {"source_row": 3, "action": "skip"},
        ]},
    )
    assert failed.status_code == 422
    with session_factory() as db:
        assert db.query(Transaction).count() == 0
        stored = db.get(ImportBatch, batch["id"])
        assert (stored.status, stored.version) == ("review", 0)
