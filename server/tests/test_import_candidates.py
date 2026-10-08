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


@pytest.mark.parametrize("options", [dict(amount_column=None), dict(debit_column="Debit"), dict(debit_column="Debit", credit_column="Credit"), dict(date_order="auto"), dict(delimiter="|"), dict(number_format="auto")])
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


@pytest.mark.parametrize(
    "date_order,value,expected",
    [
        ("ymd", "2026/9/18", "2026-09-18"),
        ("ymd", "2026.09.18", "2026-09-18"),
        ("mdy", "9-18-2026", "2026-09-18"),
        ("dmy", "18.09.2026", "2026-09-18"),
    ],
)
def test_explicit_date_order_accepts_common_consistent_separators(date_order, value, expected):
    mapping = CSVMapping("Date", "Amount", "Payee", date_order=date_order)
    rows = parse_csv_candidates(f"Date,Amount,Payee\n{value},1,Store".encode(), mapping, scale=2)
    assert rows[0].occurred_on.isoformat() == expected


@pytest.mark.parametrize("value", ["2026/09-18", "09.18/2026", "9/18/26", "2026-009-18"])
def test_explicit_date_order_rejects_mixed_or_ambiguous_shapes(value):
    mapping = CSVMapping("Date", "Amount", "Payee", date_order="ymd" if value.startswith("2026") else "mdy")
    with pytest.raises(ImportValidationError, match="Invalid date or amount") as error:
        parse_csv_candidates(f"Date,Amount,Payee\n{value},1,Private".encode(), mapping, scale=2)
    assert "Private" not in str(error.value)


@pytest.mark.parametrize(
    "number_format,value,expected",
    [
        ("dot_decimal", "1,234.56", 123456),
        ("dot_decimal", "-12,345", -1234500),
        ("comma_decimal", "1.234,56", 123456),
        ("comma_decimal", "-12.345", -1234500),
    ],
)
def test_explicit_grouping_and_decimal_conventions(number_format, value, expected):
    mapping = CSVMapping("Date", "Amount", "Payee", delimiter=";", number_format=number_format)
    rows = parse_csv_candidates(f"Date;Amount;Payee\n2026-09-18;{value};Store".encode(), mapping, scale=2)
    assert rows[0].amount_minor == expected


@pytest.mark.parametrize(
    "number_format,value",
    [
        ("dot_decimal", "1.234,56"),
        ("dot_decimal", "12,34.56"),
        ("comma_decimal", "1,234.56"),
        ("comma_decimal", "12.34,56"),
    ],
)
def test_selected_number_convention_rejects_mixed_or_malformed_grouping(number_format, value):
    mapping = CSVMapping("Date", "Amount", "Payee", delimiter=";", number_format=number_format)
    with pytest.raises(ImportValidationError, match="Invalid date or amount") as error:
        parse_csv_candidates(f"Date;Amount;Payee\n2026-09-18;{value};Private".encode(), mapping, scale=2)
    assert "Private" not in str(error.value)


def test_csv_mapping_quotes_utf8_bom_and_exact_signed_money():
    rows = parse_csv_candidates('\ufeffMemo,Payee,Amount,Date\r\n"line one\nline two","Store, café",-1.01,2026-09-18\r\nrefund,Store,0.01,2026-09-19\r\n'.encode(), MAPPING, scale=2)
    assert [r.amount_minor for r in rows] == [-101, 1]
    assert rows[0].payee == "Store, café"
    assert rows[0].memo == "line one\nline two"
    assert rows[0].occurred_on.isoformat() == "2026-09-18"


@pytest.mark.parametrize("encoding", ["utf-16-le", "utf-16-be"])
def test_bom_marked_utf16_bank_exports(encoding):
    text = "Date,Amount,Payee,Memo\r\n2026-09-18,-12.34,Caf\u00e9,statement\r\n"
    bom = b"\xff\xfe" if encoding.endswith("le") else b"\xfe\xff"
    rows = parse_csv_candidates(bom + text.encode(encoding), MAPPING, scale=2)
    assert (rows[0].amount_minor, rows[0].payee) == (-1234, "Caf\u00e9")


def test_unmarked_or_malformed_utf16_fails_closed():
    text = "Date,Amount,Payee,Memo\n2026-09-18,-1.00,Private,memo\n"
    with pytest.raises(ImportValidationError, match="UTF-8 or BOM-marked UTF-16") as error:
        parse_csv_candidates(text.encode("utf-16-le"), MAPPING, scale=2)
    assert "Private" not in str(error.value)


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
