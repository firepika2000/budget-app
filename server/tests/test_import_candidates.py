import pytest

from app.import_candidates import CSVMapping, ImportValidationError, parse_csv_candidates, parse_minor_units


MAPPING = CSVMapping("Date", "Amount", "Payee", "Memo")


def test_csv_mapping_quotes_utf8_bom_and_exact_signed_money():
    rows = parse_csv_candidates('\ufeffMemo,Payee,Amount,Date\r\n"line one\nline two","Store, café",-1.01,2026-09-18\r\nrefund,Store,0.01,2026-09-19\r\n'.encode(), MAPPING, scale=2)
    assert [r.amount_minor for r in rows] == [-101, 1]
    assert rows[0].payee == "Store, café"
    assert rows[0].memo == "line one\nline two"
    assert rows[0].occurred_on.isoformat() == "2026-09-18"


@pytest.mark.parametrize("value,scale,expected", [("92233720368547758.07", 2, 2**63-1), ("-92233720368547758.08", 2, -(2**63)), ("123", 0, 123), ("0.001", 3, 1), ("-0", 2, 0)])
def test_exact_currency_boundaries(value, scale, expected):
    assert parse_minor_units(value, scale=scale) == expected


@pytest.mark.parametrize("value", ["1e2", "NaN", "1,000.00", "$1", "1.001", "92233720368547758.08", "-92233720368547758.09", "١", "=1+2"])
def test_reject_ambiguous_or_overflow_money(value):
    with pytest.raises(ImportValidationError):
        parse_minor_units(value, scale=2)


@pytest.mark.parametrize("data", [b"Date,Amount,Payee,Memo\n2026-02-30,1,Secret,private", b"Date,Amount,Payee,Memo\n2026-09-18,1,Secret", b'Date,Amount,Payee,Memo\n"unclosed', b"Date,Amount,Payee,Payee", b"\xff", b"\x00"])
def test_malformed_input_refuses_without_disclosing_contents(data):
    with pytest.raises(ImportValidationError) as error:
        parse_csv_candidates(data, MAPPING, scale=2)
    assert "Secret" not in str(error.value)
    assert "private" not in str(error.value)


def test_bounded_large_file_and_rows():
    header = b"Date,Amount,Payee,Memo\n"
    row = b"2026-09-18,-0.01,Store,\n"
    result = parse_csv_candidates(header + row * 10_000, MAPPING, scale=2)
    assert len(result) == 10_000
    assert sum(r.amount_minor for r in result) == -10_000
    with pytest.raises(ImportValidationError, match="10000"):
        parse_csv_candidates(header + row * 10_001, MAPPING, scale=2)
    with pytest.raises(ImportValidationError, match="10 MB"):
        parse_csv_candidates(b"x" * (10 * 1024 * 1024 + 1), MAPPING, scale=2)
