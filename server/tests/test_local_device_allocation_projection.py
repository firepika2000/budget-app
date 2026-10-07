from types import SimpleNamespace

from app.local_device_export import _allocation_rows


def posting(identifier: str, category_id: str, amount_minor: int):
    return SimpleNamespace(
        id=identifier, operation_id="operation", bucket="category",
        category_id=category_id, amount_minor=amount_minor,
    )


def test_many_to_many_allocation_is_decomposed_without_changing_category_observations():
    operation = SimpleNamespace(
        id="operation", budget_id="budget", occurred_on="2026-10-07",
        kind="move", actor_user_id="owner", note="Rebalance", created_at="2026-10-07T12:00:00Z",
    )
    values = [
        posting("source-a", "source-a", -700),
        posting("source-b", "source-b", -300),
        posting("destination-a", "destination-a", 400),
        posting("destination-b", "destination-b", 600),
    ]

    rows = _allocation_rows([operation], values)

    assert [(row["source_category_id"], row["category_id"], row["amount_minor"]) for row in rows] == [
        ("source-a", "destination-a", 400),
        ("source-a", "destination-b", 300),
        ("source-b", "destination-b", 300),
    ]
    net = {}
    for row in rows:
        net[row["source_category_id"]] = net.get(row["source_category_id"], 0) - row["amount_minor"]
        net[row["category_id"]] = net.get(row["category_id"], 0) + row["amount_minor"]
        assert row["operation_id"] == "operation"
    assert net == {
        "source-a": -700, "source-b": -300,
        "destination-a": 400, "destination-b": 600,
    }


def test_unbalanced_allocation_still_fails_closed():
    operation = SimpleNamespace(
        id="operation", budget_id="budget", occurred_on="2026-10-07",
        kind="move", actor_user_id="owner", note="", created_at="2026-10-07T12:00:00Z",
    )
    values = [posting("source", "source", -500), posting("destination", "destination", 499)]

    try:
        _allocation_rows([operation], values)
    except ValueError as error:
        assert str(error) == "Allocation operation is not balanced"
    else:
        raise AssertionError("unbalanced allocation must fail closed")
