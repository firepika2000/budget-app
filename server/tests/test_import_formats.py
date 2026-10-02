import pytest

from app.import_candidates import ImportValidationError
from app.import_formats import parse_ofx_candidates, parse_qif_candidates


def test_ofx_xml_and_sgml_transactions_preserve_exact_signed_money():
    data = b"""OFXHEADER:100\n<OFX><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261002120000[-4:EDT]<TRNAMT>-12.34<NAME>Corner Store<MEMO>card purchase
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261003</DTPOSTED><TRNAMT>2.34</TRNAMT><NAME>Corner Store</NAME><MEMO>refund</MEMO></STMTTRN>
</BANKTRANLIST></OFX>"""
    rows = parse_ofx_candidates(data, scale=2)
    assert [(row.occurred_on.isoformat(), row.amount_minor, row.payee, row.memo) for row in rows] == [
        ("2026-10-02", -1234, "Corner Store", "card purchase"),
        ("2026-10-03", 234, "Corner Store", "refund"),
    ]


def test_qfx_payee_fallback_and_timezone_do_not_change_posted_date():
    rows = parse_ofx_candidates(
        b"<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260228235959.000[-8:PST]</DTPOSTED><TRNAMT>-1.01</TRNAMT><PAYEE>Cafe</PAYEE></STMTTRN></BANKTRANLIST></OFX>",
        scale=2,
    )
    assert rows[0].occurred_on.isoformat() == "2026-02-28"
    assert rows[0].amount_minor == -101
    assert rows[0].payee == "Cafe"


def test_qif_requires_explicit_date_order_and_supports_grouped_amounts():
    data = b"!Type:Bank\nD10/02/2026\nT-1,234.56\nPUtility Company\nMSeptember bill\n^\nD10/03/2026\nT25.00\nPRefund\n^\n"
    rows = parse_qif_candidates(data, scale=2, date_order="mdy")
    assert [(row.occurred_on.isoformat(), row.amount_minor) for row in rows] == [
        ("2026-10-02", -123456), ("2026-10-03", 2500)
    ]
    with pytest.raises(ImportValidationError, match="explicit"):
        parse_qif_candidates(data, scale=2, date_order="auto")


def test_qif_two_digit_year_is_deterministic():
    data = b"D31/12/'69\nT1.00\nPInterest\n^\nD01/01/'70\nT1.00\nPInterest\n^"
    rows = parse_qif_candidates(data, scale=2, date_order="dmy")
    assert [row.occurred_on.isoformat() for row in rows] == ["2069-12-31", "1970-01-01"]


@pytest.mark.parametrize("data", [
    b"<OFX><BANKTRANLIST></BANKTRANLIST></OFX>",
    b"<!DOCTYPE OFX [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><OFX><STMTTRN><DTPOSTED>20261002<TRNAMT>1</STMTTRN></OFX>",
    b"<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260230<TRNAMT>1<NAME>Private</STMTTRN></BANKTRANLIST></OFX>",
    b"<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20261002<NAME>Private</STMTTRN></BANKTRANLIST></OFX>",
])
def test_ofx_refuses_malformed_or_unsafe_input_without_private_content(data):
    with pytest.raises(ImportValidationError) as error:
        parse_ofx_candidates(data, scale=2)
    assert "Private" not in str(error.value)
    assert "passwd" not in str(error.value)


@pytest.mark.parametrize("data", [
    b"!Type:Bank\n^",
    b"D02/30/2026\nT1.00\nPPrivate\n^",
    b"D10/02/2026\nT1e2\nPPrivate\n^",
    b"D10/02/2026\nPPrivate\n^",
])
def test_qif_refuses_malformed_input_without_private_content(data):
    with pytest.raises(ImportValidationError) as error:
        parse_qif_candidates(data, scale=2, date_order="mdy")
    assert "Private" not in str(error.value)


def test_ofx_and_qif_enforce_file_and_row_bounds():
    with pytest.raises(ImportValidationError, match="10 MB"):
        parse_ofx_candidates(b"x" * (10 * 1024 * 1024 + 1), scale=2)
    ofx_record = b"<STMTTRN><DTPOSTED>20261002<TRNAMT>-0.01<NAME>Store</STMTTRN>"
    assert len(parse_ofx_candidates(b"<BANKTRANLIST>" + ofx_record * 10_000 + b"</BANKTRANLIST>", scale=2)) == 10_000
    with pytest.raises(ImportValidationError, match="10000"):
        parse_ofx_candidates(b"<BANKTRANLIST>" + ofx_record * 10_001 + b"</BANKTRANLIST>", scale=2)

    qif_record = b"D10/02/2026\nT-0.01\nPStore\n^\n"
    assert len(parse_qif_candidates(qif_record * 10_000, scale=2, date_order="mdy")) == 10_000
    with pytest.raises(ImportValidationError, match="10000"):
        parse_qif_candidates(qif_record * 10_001, scale=2, date_order="mdy")
