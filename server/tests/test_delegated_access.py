from app.models import AllocationOperation, FinancialRequest, Household, Membership, RequestAction, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_budgeting_api import create_budget, create_budget_structure


def add_child(session_factory, client):
    with session_factory() as db:
        household = db.query(Household).one()
        child = User(
            email="child@example.com",
            display_name="Child",
            password_hash=hash_password("child password long enough"),
        )
        db.add(child)
        db.flush()
        db.add(Membership(household_id=household.id, user_id=child.id, role="child"))
        db.commit()
        return child.id, create_access_token(child.id, client.app.state.settings)


def configure_child(client, owner_token, budget_id, child_id, account_id, category_id):
    category_ids = category_id if isinstance(category_id, list) else [category_id]
    grant = client.put(
        f"/api/v1/budgets/{budget_id}/grants",
        headers=auth(owner_token),
        json={"user_id": child_id, "permission": "contribute"},
    )
    assert grant.status_code == 200, grant.text
    profile = client.put(
        f"/api/v1/budgets/{budget_id}/access/{child_id}",
        headers=auth(owner_token),
        json={
            "capabilities": [
                "view_budget", "view_accounts", "view_categories", "view_transactions",
                "view_reports", "create_transaction", "request_money",
            ],
            "restrict_accounts": True,
            "account_ids": [account_id],
            "restrict_categories": True,
            "category_ids": category_ids,
        },
    )
    assert profile.status_code == 200, profile.text


def test_scoped_child_cannot_discover_hidden_financial_resources(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    child_category = add_category(
        client, owner_token, budget["id"], "Delegated", "Child Entertainment"
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=100000,
        is_cleared=True,
        payee_name="Private salary",
    )
    child_id, child_token = add_child(session_factory, client)
    configure_child(
        client, owner_token, budget["id"], child_id, checking["id"], child_category["id"]
    )

    categories = client.get(
        f"/api/v1/budgets/{budget['id']}/categories", headers=auth(child_token)
    )
    assert [item["id"] for item in categories.json()] == [child_category["id"]]
    assert groceries["id"] not in categories.text
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(child_token)
    ).json()[0]["id"] == checking["id"]
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/accounts/{checking['id']}/balance",
        headers=auth(child_token),
    ).status_code == 403
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(child_token)
    ).json() == []
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/forecast?through=2026-10-01",
        headers=auth(child_token),
    ).status_code == 403
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/allocations",
        headers=auth(child_token),
    ).status_code == 403

    own_spending = record(
        client,
        child_token,
        budget["id"],
        account_id=checking["id"],
        category_id=child_category["id"],
        amount_minor=-500,
        is_cleared=False,
        payee_name="Game",
    )
    visible_transactions = client.get(
        f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(child_token)
    ).json()
    assert [item["id"] for item in visible_transactions] == [own_spending["id"]]

    response = client.post(
        f"/api/v1/budgets/{budget['id']}/transactions",
        headers=auth(child_token),
        json={
            "account_id": checking["id"],
            "category_id": groceries["id"],
            "amount_minor": -100,
            "occurred_on": "2026-09-04",
        },
    )
    assert response.status_code == 422

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(child_token),
    ).json()
    assert summary["ready_to_assign_minor"] == 0
    assert [item["category_id"] for item in summary["categories"]] == [child_category["id"]]


def test_partial_request_approval_moves_existing_allocation_once_and_is_auditable(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    source = add_category(client, owner_token, budget["id"], "Family", "Allowance Pool")
    destination = add_category(
        client, owner_token, budget["id"], "Delegated", "Child Entertainment"
    )
    record(
        client,
        owner_token,
        budget["id"],
        account_id=checking["id"],
        amount_minor=20000,
        is_cleared=True,
    )
    assignment = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{source['id']}/assignment",
        headers=auth(owner_token),
        json={"month": "2026-09-01", "assigned_minor": 20000},
    )
    assert assignment.status_code == 200, assignment.text

    child_id, child_token = add_child(session_factory, client)
    configure_child(
        client, owner_token, budget["id"], child_id, checking["id"], destination["id"]
    )
    submitted = client.post(
        f"/api/v1/budgets/{budget['id']}/requests",
        headers=auth(child_token),
        json={
            "destination_category_id": destination["id"],
            "requested_amount_minor": 5000,
            "reason": "New game",
        },
    )
    assert submitted.status_code == 201, submitted.text
    request = submitted.json()

    approved = client.post(
        f"/api/v1/budgets/{budget['id']}/requests/{request['id']}/decision",
        headers=auth(owner_token),
        json={
            "decision": "approve",
            "expected_request_version": 0,
            "approved_amount_minor": 3000,
            "source_category_id": source["id"],
            "note": "Partial amount approved",
        },
    )
    assert approved.status_code == 200, approved.text
    result = approved.json()
    assert result["status"] == "partially_approved"
    assert result["approved_amount_minor"] == 3000
    assert result["allocation_operation_id"]
    assert [action["action"] for action in result["actions"]] == [
        "submitted", "partially_approved"
    ]
    assert result["actions"][0]["actor_user_id"] == child_id
    assert result["actions"][1]["actor_user_id"] != child_id

    stale = client.post(
        f"/api/v1/budgets/{budget['id']}/requests/{request['id']}/decision",
        headers=auth(owner_token),
        json={
            "decision": "approve",
            "expected_request_version": 0,
            "approved_amount_minor": 3000,
            "source_category_id": source["id"],
        },
    )
    assert stale.status_code == 409

    child_view = client.get(
        f"/api/v1/budgets/{budget['id']}/requests", headers=auth(child_token)
    ).json()[0]
    assert child_view["source_category_id"] is None

    summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01",
        headers=auth(owner_token),
    ).json()
    by_id = {item["category_id"]: item for item in summary["categories"]}
    assert by_id[source["id"]]["available_minor"] == 17000
    assert by_id[destination["id"]]["available_minor"] == 3000
    assert summary["ready_to_assign_minor"] == 0

    with session_factory() as db:
        stored = db.get(FinancialRequest, request["id"])
        operation = db.get(AllocationOperation, stored.allocation_operation_id)
        assert operation.kind == "request_approval"
        assert operation.source == "approval"
        assert sum(posting.amount_minor for posting in operation.postings) == 0
        assert db.query(RequestAction).filter_by(request_id=request["id"]).count() == 2
