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
    scoped_accounts = client.get(
        f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(child_token)
    ).json()
    assert scoped_accounts[0]["id"] == checking["id"]
    assert scoped_accounts[0]["reconciled_balance_minor"] is None
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


def test_rejected_and_cancelled_requests_survive_member_deactivation(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    destination = add_category(
        client, owner_token, budget["id"], "Delegated", "Child Requests"
    )
    child_id, child_token = add_child(session_factory, client)
    configure_child(
        client, owner_token, budget["id"], child_id, checking["id"], destination["id"]
    )

    cancelled = client.post(
        f"/api/v1/budgets/{budget['id']}/requests",
        headers=auth(child_token),
        json={"destination_category_id": destination["id"], "requested_amount_minor": 1000},
    ).json()
    cancelled_response = client.post(
        f"/api/v1/budgets/{budget['id']}/requests/{cancelled['id']}/cancel",
        headers=auth(child_token),
        json={"expected_request_version": 0, "note": "Changed my mind"},
    )
    assert cancelled_response.status_code == 200
    assert cancelled_response.json()["status"] == "cancelled"

    rejected = client.post(
        f"/api/v1/budgets/{budget['id']}/requests",
        headers=auth(child_token),
        json={"destination_category_id": destination["id"], "requested_amount_minor": 2000},
    ).json()
    rejected_response = client.post(
        f"/api/v1/budgets/{budget['id']}/requests/{rejected['id']}/decision",
        headers=auth(owner_token),
        json={"decision": "reject", "expected_request_version": 0, "note": "Not this week"},
    )
    assert rejected_response.status_code == 200
    assert rejected_response.json()["status"] == "rejected"

    removed = client.delete(
        f"/api/v1/households/{budget['household_id']}/members/{child_id}",
        headers=auth(owner_token),
    )
    assert removed.status_code == 204
    with session_factory() as db:
        stored = db.query(FinancialRequest).filter_by(requester_user_id=child_id).all()
        assert {item.status for item in stored} == {"cancelled", "rejected"}
        assert db.query(RequestAction).filter(
            RequestAction.request_id.in_([item.id for item in stored])
        ).count() == 4


def test_delegated_member_can_create_only_own_scoped_category(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    seed = add_category(client, owner_token, budget["id"], "Delegated", "Alex Other")
    groups = client.get(
        f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token)
    ).json()
    delegated_group = next(group for group in groups if group["name"] == "Delegated")
    child_id, child_token = add_child(session_factory, client)
    delegated_seed = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{seed['id']}/delegation",
        headers=auth(owner_token), json={"delegated_user_id": child_id},
    )
    assert delegated_seed.status_code == 200, delegated_seed.text
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], seed["id"])

    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}",
        headers=auth(owner_token),
        json={
            "capabilities": [
                "view_budget", "view_accounts", "view_categories", "view_transactions",
                "view_reports", "create_transaction", "request_money", "move_money",
                "manage_own_categories", "assign_money",
            ],
            "restrict_accounts": True,
            "account_ids": [checking["id"]],
            "restrict_categories": True,
            "category_ids": [seed["id"]],
        },
    )
    assert profile.status_code == 200, profile.text
    record(
        client, owner_token, budget["id"], account_id=checking["id"],
        amount_minor=20000, is_cleared=True, payee_name="Delegation funding",
    )

    policy = client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}",
        headers=auth(owner_token),
        json={
            "user_id": child_id,
            "pool_category_id": seed["id"],
            "authority_minor": 20000,
            "allow_category_creation": True,
            "allow_reallocation": True,
            "rules": [],
        },
    )
    assert policy.status_code == 200, policy.text
    assert policy.json()["available_to_assign_minor"] == 20000
    owner_summary = client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()
    assert owner_summary["ready_to_assign_minor"] == 0

    bypass = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{seed['id']}/assignment",
        headers=auth(child_token),
        json={"month": "2026-09-01", "assigned_minor": 1},
    )
    assert bypass.status_code == 403
    assert client.get(
        f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)
    ).json()["ready_to_assign_minor"] == 0

    created = client.post(
        f"/api/v1/budgets/{budget['id']}/categories",
        headers=auth(child_token),
        json={
            "group_id": delegated_group["id"],
            "name": "Concert Fund",
            "delegated_user_id": child_id,
        },
    )
    assert created.status_code == 201, created.text
    assert created.json()["delegated_user_id"] == child_id
    visible_ids = {
        item["id"] for item in client.get(
            f"/api/v1/budgets/{budget['id']}/categories", headers=auth(child_token)
        ).json()
    }
    assert created.json()["id"] in visible_ids

    forbidden = client.post(
        f"/api/v1/budgets/{budget['id']}/categories",
        headers=auth(child_token),
        json={"group_id": delegated_group["id"], "name": "Parent Money"},
    )
    assert forbidden.status_code == 403


def test_delegated_reallocation_stays_inside_boundary_and_enforces_rules(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, parent_category = create_budget_structure(client, owner_token, budget["id"])
    pool = add_category(client, owner_token, budget["id"], "Delegated", "Alex To Assign")
    games = add_category(client, owner_token, budget["id"], "Delegated", "Games")
    savings = add_category(client, owner_token, budget["id"], "Delegated", "Savings")
    child_id, child_token = add_child(session_factory, client)
    for category in (pool, games, savings):
        delegated = client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/delegation",
            headers=auth(owner_token), json={"delegated_user_id": child_id},
        )
        assert delegated.status_code == 200, delegated.text
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], [pool["id"], games["id"], savings["id"]])
    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={
            "capabilities": ["view_budget", "view_categories", "view_transactions", "move_money", "request_money"],
            "restrict_accounts": True, "account_ids": [checking["id"]],
            "restrict_categories": True, "category_ids": [pool["id"], games["id"], savings["id"]],
        },
    )
    assert profile.status_code == 200, profile.text
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=20000, is_cleared=True)
    assigned = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{pool['id']}/assignment",
        headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 20000},
    )
    assert assigned.status_code == 200, assigned.text
    policy = client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}", headers=auth(owner_token),
        json={
            "user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 20000,
            "rules": [{"category_id": savings["id"], "rule_kind": "hard_limit", "minimum_minor": 4000}],
        },
    )
    assert policy.status_code == 200, policy.text
    moved = client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
        json={"source_category_id": pool["id"], "destination_category_id": savings["id"], "amount_minor": 5000, "occurred_on": "2026-09-04"},
    )
    assert moved.status_code == 201, moved.text
    blocked_minimum = client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
        json={"source_category_id": savings["id"], "destination_category_id": games["id"], "amount_minor": 1001, "occurred_on": "2026-09-04"},
    )
    assert blocked_minimum.status_code == 409
    hidden_parent = client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
        json={"source_category_id": games["id"], "destination_category_id": parent_category["id"], "amount_minor": 100, "occurred_on": "2026-09-04"},
    )
    assert hidden_parent.status_code in {403, 404}
    own_summary = client.get(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/me", headers=auth(child_token)
    )
    assert own_summary.status_code == 200, own_summary.text
    assert own_summary.json()["available_to_assign_minor"] == 15000

    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=5000, is_cleared=True, payee_name="Authority increase")
    version = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["allocation_version"]
    increased = client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}", headers=auth(owner_token),
        json={"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 25000, "expected_allocation_version": version, "rules": [{"category_id": savings["id"], "rule_kind": "hard_limit", "minimum_minor": 4000}]},
    )
    assert increased.status_code == 200, increased.text
    assert increased.json()["available_to_assign_minor"] == 20000
    stale_increase = client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}", headers=auth(owner_token),
        json={"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 26000, "expected_allocation_version": version, "rules": []},
    )
    assert stale_increase.status_code == 409
    invalid_reduction = client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}", headers=auth(owner_token),
        json={"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 4000, "rules": []},
    )
    assert invalid_reduction.status_code == 409


def test_delegated_member_can_rename_move_and_archive_only_own_category(
    client, owner_token, session_factory
):
    budget = create_budget(client, owner_token, session_factory)
    checking, parent_category = create_budget_structure(client, owner_token, budget["id"])
    own = add_category(client, owner_token, budget["id"], "Delegated", "Games")
    second_group_category = add_category(client, owner_token, budget["id"], "Savings", "Seed")
    groups = client.get(f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token)).json()
    savings_group = next(item for item in groups if item["id"] == second_group_category["group_id"])
    child_id, child_token = add_child(session_factory, client)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{own['id']}/delegation", headers=auth(owner_token), json={"delegated_user_id": child_id})
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], [own["id"], parent_category["id"]])
    profile = client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={"capabilities": ["view_budget", "view_categories", "manage_own_categories"], "restrict_accounts": True, "account_ids": [checking["id"]], "restrict_categories": True, "category_ids": [own["id"], parent_category["id"]]},
    )
    assert profile.status_code == 200, profile.text

    updated = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{own['id']}", headers=auth(child_token),
        json={"group_id": savings_group["id"], "name": "Long-term Games", "sort_order": 4, "is_archived": True},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["name"] == "Long-term Games"
    assert updated.json()["group_id"] == savings_group["id"]
    assert updated.json()["is_archived"] is True

    forbidden = client.put(
        f"/api/v1/budgets/{budget['id']}/categories/{parent_category['id']}", headers=auth(child_token),
        json={"group_id": savings_group["id"], "name": "Private Parent", "is_archived": True},
    )
    assert forbidden.status_code == 403
