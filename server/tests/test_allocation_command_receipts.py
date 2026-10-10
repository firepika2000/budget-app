from uuid import uuid4
import pytest

from app.models import AllocationOperation, WorkspaceCommandReceipt, User
from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure, add_member
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund


def setup_plan(client, token, session_factory):
    budget = create_budget(client, token, session_factory)
    account, source = create_budget_structure(client, token, budget["id"])
    destination = add_category(client, token, budget["id"], "Other", "Destination")
    fund(client, token, budget["id"], account["id"], amount=10000)
    root = f"/api/v1/budgets/{budget['id']}"
    response = client.put(f"{root}/categories/{source['id']}/assignment", headers=auth(token),
                          json={"month": "2026-09-01", "assigned_minor": 4000, "expected_allocation_version": 0})
    assert response.status_code == 200, response.text
    return budget, account, source, destination, root


def command(kind, root, source, destination):
    if kind == "assignment":
        return "put", f"{root}/categories/{source['id']}/assignment", {
            "month": "2026-09-01", "assigned_minor": 5000,
            "expected_allocation_version": 1, "mutation_operation_id": str(uuid4())}
    return "post", f"{root}/allocation-transfers", {
        "source_category_id": source["id"], "destination_category_id": destination["id"],
        "amount_minor": 1000, "occurred_on": "2026-09-04", "note": "Saved intent",
        "expected_allocation_version": 1, "mutation_operation_id": str(uuid4())}


@pytest.mark.parametrize("kind", ["assignment", "move"])
def test_identified_allocation_retry_never_reallocates_or_reverts_later_plan(client, owner_token, session_factory, kind):
    _, account, source, destination, root = setup_plan(client, owner_token, session_factory)
    method, path, body = command(kind, root, source, destination)
    send = getattr(client, method)
    balance = client.get(f"{root}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
    first = send(path, headers=auth(owner_token), json=body)
    assert first.status_code == (200 if kind == "assignment" else 201), first.text
    with session_factory() as db:
        count = db.query(AllocationOperation).count()
    retry = send(path, headers=auth(owner_token), json=body)
    assert retry.status_code == first.status_code, retry.text
    assert retry.json()["allocation_version"] == 2
    later = client.put(f"{root}/categories/{source['id']}/assignment", headers=auth(owner_token),
                       json={"month": "2026-09-01", "assigned_minor": 2500, "expected_allocation_version": 2})
    assert later.status_code == 200, later.text
    observations = client.get(f"{root}/months/2026-09-01", headers=auth(owner_token)).json()
    acknowledged = send(path, headers=auth(owner_token), json=body)
    assert acknowledged.status_code == first.status_code, acknowledged.text
    assert acknowledged.json()["allocation_version"] == 3
    if kind == "assignment":
        assert acknowledged.json()["assigned_minor"] == 2500
    else:
        assert acknowledged.json()["id"] == first.json()["id"]
    changed = {**body, ("assigned_minor" if kind == "assignment" else "amount_minor"): 2000}
    assert send(path, headers=auth(owner_token), json=changed).status_code == 409
    assert send(path, headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    assert client.get(f"{root}/months/2026-09-01", headers=auth(owner_token)).json() == observations
    assert client.get(f"{root}/accounts/{account['id']}/balance", headers=auth(owner_token)).json() == balance
    with session_factory() as db:
        assert db.query(AllocationOperation).count() == count + 1
        assert db.query(WorkspaceCommandReceipt).count() == 1


@pytest.mark.parametrize("kind", ["assignment", "move"])
@pytest.mark.parametrize("restriction", ["category", "capability"])
def test_allocation_acknowledgement_rechecks_current_authority(client, owner_token, session_factory, kind, restriction):
    budget, _, source, destination, root = setup_plan(client, owner_token, session_factory)
    token = add_member(session_factory, client, "manage", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="manage@example.com").one().id
    capabilities = ["view_budget", "assign_money", "move_money"]
    access = {"capabilities": capabilities, "restrict_accounts": False, "account_ids": [],
              "restrict_categories": False, "category_ids": []}
    assert client.put(f"{root}/access/{member}", headers=auth(owner_token), json=access).status_code == 200
    method, path, body = command(kind, root, source, destination)
    send = getattr(client, method)
    assert send(path, headers=auth(token), json=body).status_code in {200, 201}
    if restriction == "category":
        access["restrict_categories"] = True
    else:
        access["capabilities"] = ["view_budget"]
    assert client.put(f"{root}/access/{member}", headers=auth(owner_token), json=access).status_code == 200
    response = send(path, headers=auth(token), json=body)
    assert response.status_code == (404 if restriction == "category" else 403), response.text
    assert "Saved intent" not in response.text


@pytest.mark.parametrize("kind", ["assignment", "move"])
def test_identified_allocation_requires_version(client, owner_token, session_factory, kind):
    _, _, source, destination, root = setup_plan(client, owner_token, session_factory)
    method, path, body = command(kind, root, source, destination)
    body.pop("expected_allocation_version")
    assert getattr(client, method)(path, headers=auth(owner_token), json=body).status_code == 422
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 0


def test_noop_assignment_receipt_does_not_restore_old_plan(client, owner_token, session_factory):
    _, _, source, _, root = setup_plan(client, owner_token, session_factory)
    path = f"{root}/categories/{source['id']}/assignment"
    body = {"month": "2026-09-01", "assigned_minor": 4000,
            "expected_allocation_version": 1, "mutation_operation_id": str(uuid4())}
    assert client.put(path, headers=auth(owner_token), json=body).json()["allocation_version"] == 1
    assert client.put(path, headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 3000,
                                                          "expected_allocation_version": 1}).status_code == 200
    retry = client.put(path, headers=auth(owner_token), json=body)
    assert retry.status_code == 200 and retry.json()["assigned_minor"] == 3000
    with session_factory() as db:
        assert db.query(WorkspaceCommandReceipt).count() == 1
        assert db.query(AllocationOperation).count() == 2


def test_move_receipt_does_not_bypass_revoked_delegated_reallocation(client, owner_token, session_factory):
    from .test_delegated_access import _delegate_with_pool
    budget, _, pool, games, child_id, child_token = _delegate_with_pool(
        client, owner_token, session_factory, capabilities=["view_budget", "view_categories", "move_money"])
    root = f"/api/v1/budgets/{budget['id']}"
    version = client.get(f"{root}/months/2026-09-01", headers=auth(owner_token)).json()["allocation_version"]
    body = {"source_category_id": pool["id"], "destination_category_id": games["id"], "amount_minor": 100,
            "occurred_on": "2026-09-04", "expected_allocation_version": version, "mutation_operation_id": str(uuid4())}
    first = client.post(f"{root}/allocation-transfers", headers=auth(child_token), json=body)
    assert first.status_code == 201, first.text
    assert client.post(f"{root}/allocation-transfers", headers=auth(child_token), json=body).status_code == 201
    policy = {"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 20000,
              "allow_reallocation": False, "rules": []}
    assert client.put(f"{root}/delegated-budgets/{child_id}", headers=auth(owner_token), json=policy).status_code == 200
    assert client.post(f"{root}/allocation-transfers", headers=auth(child_token), json=body).status_code == 403
