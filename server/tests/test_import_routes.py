from app.models import ImportBatch, Transaction

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


def test_ofx_qfx_and_qif_use_the_same_owned_staging_boundary(client, owner_token, session_factory):
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
