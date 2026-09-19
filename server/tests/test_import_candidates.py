import pytest

from app.import_candidates import CSVMapping, ImportValidationError, parse_csv_candidates, parse_minor_units


MAPPING = CSVMapping("Date", "Amount", "Payee", "Memo")


def test_explicit_debit_credit_mapping_and_date_order():
    data = b"Date;Debit;Credit;Payee\n02/03/2026;2.01;;Store\n03/04/2026;;5.00;Refund\n"
    for order, expected in [("mdy", "2026-02-03"), ("dmy", "2026-03-02")]:
        mapping = CSVMapping("Date", None, "Payee", debit_column="Debit", credit_column="Credit", date_order=order, delimiter=";")
        rows = parse_csv_candidates(data, mapping, scale=2)
        assert rows[0].occurred_on.isoformat() == expected
        assert [r.amount_minor for r in rows] == [-201, 500]


@pytest.mark.parametrize("debit,credit", [("1", "2"), ("-1", ""), ("", "-1"), ("", ""), ("1.001", ""), ("92233720368547758.08", "")])
def test_split_amount_columns_refuse_ambiguous_or_invalid_values(debit, credit):
    mapping = CSVMapping("Date", None, "Payee", debit_column="Debit", credit_column="Credit")
    with pytest.raises(ImportValidationError):
        parse_csv_candidates(f"Date,Debit,Credit,Payee\n2026-09-18,{debit},{credit},Store".encode(), mapping, scale=2)


@pytest.mark.parametrize("options", [dict(amount_column=None), dict(debit_column="Debit"), dict(debit_column="Debit", credit_column="Credit"), dict(date_order="auto"), dict(delimiter="|")])
def test_invalid_mapping_rejected_even_for_empty_file(options):
    arguments = dict(date_column="Date", amount_column="Amount", payee_column="Payee")
    arguments.update(options)
    with pytest.raises(ImportValidationError):
        parse_csv_candidates(b"", CSVMapping(**arguments), scale=2)


def test_tab_delimited_input_and_explicit_leap_date():
    mapping = CSVMapping("Date", "Amount", "Payee", date_order="dmy", delimiter="\t")
    rows = parse_csv_candidates(b"Date\tAmount\tPayee\n29/2/2024\t1\tStore", mapping, scale=2)
    assert rows[0].occurred_on.isoformat() == "2024-02-29"
    with pytest.raises(ImportValidationError):
        parse_csv_candidates(b"Date\tAmount\tPayee\n29/2/2025\t1\tStore", mapping, scale=2)


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
