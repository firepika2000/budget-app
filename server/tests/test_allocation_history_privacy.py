"""Allocation history must not bypass category scope through notes or counterpart postings."""

from .conftest import auth
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child
from .test_targets_contract import grant_scoped_planner


def test_allocation_history_filters_complete_operations_before_exposing_metadata(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    account, visible = create_budget_structure(client, owner_token, budget["id"])
    hidden = add_category(client, owner_token, budget["id"], "Private", "Secret medical fund")
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    root = f"/api/v1/budgets/{budget['id']}"
    for category in (visible, hidden):
        response = client.put(f"{root}/categories/{category['id']}/assignment", headers=auth(owner_token),
                              json={"month": "2026-09-01", "assigned_minor": 30000})
        assert response.status_code == 200
    move = client.post(f"{root}/allocation-transfers", headers=auth(owner_token), json={
        "source_category_id": hidden["id"], "destination_category_id": visible["id"],
        "amount_minor": 1234, "occurred_on": "2026-09-01", "note": "Secret medical treatment",
    })
    assert move.status_code == 201
    owner_history = client.get(f"{root}/allocations", headers=auth(owner_token)).json()
    assert len(owner_history) == 3
    visible_operation = next(row for row in owner_history if row["kind"] == "assignment"
                             and any(p["category_id"] == visible["id"] for p in row["postings"]))
    child_id, token = add_child(session_factory, client)

    def grant(categories, capabilities=("view_budget", "view_allocation_history")):
        grant_scoped_planner(client, owner_token, budget["id"], child_id, account["id"], categories,
                             list(capabilities))

    grant([visible["id"]])
    scoped = client.get(f"{root}/allocations", headers=auth(token))
    assert scoped.status_code == 200
    assert scoped.json() == [visible_operation]
    assert hidden["id"] not in scoped.text
    assert "Secret" not in scoped.text
    assert move.json()["id"] not in scoped.text
    # Do not expose half a balanced operation or its private free-text note.
    assert all(sum(p["amount_minor"] for p in row["postings"]) == 0 for row in scoped.json())

    grant([visible["id"], hidden["id"]])
    assert client.get(f"{root}/allocations", headers=auth(token)).json() == owner_history
    grant([])
    assert client.get(f"{root}/allocations", headers=auth(token)).json() == []
    grant([visible["id"]], capabilities=("view_budget",))
    assert client.get(f"{root}/allocations", headers=auth(token)).status_code == 403
    assert client.get(f"{root}/allocations").status_code == 401
    other = create_budget(client, owner_token, session_factory, name="Separate private budget")
    assert client.get(f"/api/v1/budgets/{other['id']}/allocations", headers=auth(token)).status_code == 404
    # Grant changes and reads never alter canonical financial history.
    assert client.get(f"{root}/allocations", headers=auth(owner_token)).json() == owner_history
