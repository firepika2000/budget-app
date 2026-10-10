import pytest

from app.models import AllocationOperation, DelegatedBudgetPolicyRevision, User
from .conftest import auth
from .test_budgeting_api import add_member
from .test_delegated_access import _delegate_with_pool


@pytest.mark.parametrize("scope", ["hidden_pool", "hidden_rules", "hidden_controlled"])
def test_scoped_manager_cannot_read_or_change_private_delegated_policy(client, owner_token, session_factory, scope):
    budget, account, pool, games, child_id, _ = _delegate_with_pool(
        client, owner_token, session_factory, capabilities=["view_budget", "view_categories"])
    root = f"/api/v1/budgets/{budget['id']}/delegated-budgets"
    rules = [{"category_id": games["id"], "rule_kind": "hard_limit", "maximum_minor": 12345}] if scope == "hidden_rules" else []
    body = {"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 20000, "rules": rules}
    assert client.put(f"{root}/{child_id}", headers=auth(owner_token), json=body).status_code == 200
    token = add_member(session_factory, client, "manage", budget["id"])
    with session_factory() as db:
        manager_id = db.query(User).filter_by(email="manage@example.com").one().id
    visible = [games["id"]] if scope == "hidden_pool" else [pool["id"]]
    grant = client.put(f"/api/v1/budgets/{budget['id']}/access/{manager_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_categories", "manage_allowances"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": visible,
    })
    assert grant.status_code == 200, grant.text
    before = client.get(root, headers=auth(owner_token)).json()
    with session_factory() as db:
        operations = db.query(AllocationOperation).count()
        decisions = db.query(DelegatedBudgetPolicyRevision).count()
    listed = client.get(root, headers=auth(token))
    assert listed.status_code == 200, listed.text
    assert listed.json() == [], "Manager capability does not authorize hidden delegated policy resources"
    assert client.get(f"{root}/{child_id}/history", headers=auth(token)).status_code == 404
    denied = client.put(f"{root}/{child_id}", headers=auth(token), json={**body, "allow_reallocation": False})
    assert denied.status_code == 404, denied.text
    assert client.get(root, headers=auth(owner_token)).json() == before
    with session_factory() as db:
        assert db.query(AllocationOperation).count() == operations
        assert db.query(DelegatedBudgetPolicyRevision).count() == decisions


def test_fully_scoped_manager_retains_policy_management_but_not_private_historical_snapshots(client, owner_token, session_factory):
    budget, account, pool, games, child_id, _ = _delegate_with_pool(
        client, owner_token, session_factory, capabilities=["view_budget", "view_categories"])
    root = f"/api/v1/budgets/{budget['id']}/delegated-budgets"
    token = add_member(session_factory, client, "manage", budget["id"])
    with session_factory() as db:
        manager_id = db.query(User).filter_by(email="manage@example.com").one().id
    grant = client.put(f"/api/v1/budgets/{budget['id']}/access/{manager_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_categories", "manage_allowances"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [pool["id"], games["id"]],
    })
    assert grant.status_code == 200, grant.text
    listed = client.get(root, headers=auth(token))
    assert listed.status_code == 200 and len(listed.json()) == 1
    assert client.get(f"{root}/{child_id}/history", headers=auth(token)).status_code == 200
    updated = client.put(f"{root}/{child_id}", headers=auth(token), json={
        "user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 20000,
        "allow_reallocation": False, "rules": [],
    })
    assert updated.status_code == 200, updated.text
    assert updated.json()["allow_reallocation"] is False
    # An older snapshot can reference a resource outside today's otherwise valid policy.
    with session_factory() as db:
        decision = db.query(DelegatedBudgetPolicyRevision).filter_by(member_user_id=child_id).first()
        decision.after_snapshot = {**decision.after_snapshot,
                                   "rules": [{"category_id": "private-historical-category", "rule_kind": "hard_limit", "maximum_minor": 98765}]}
        db.commit()
    response = client.get(f"{root}/{child_id}/history", headers=auth(token))
    assert response.status_code == 404, response.text
    assert "private-historical-category" not in response.text and "98765" not in response.text
    assert client.get(f"{root}/{child_id}/history", headers=auth(owner_token)).status_code == 200


def test_own_policy_becomes_empty_without_leaking_hidden_pool(client, owner_token, session_factory):
    budget, account, pool, games, child_id, token = _delegate_with_pool(
        client, owner_token, session_factory, capabilities=["view_budget", "view_categories"])
    url = f"/api/v1/budgets/{budget['id']}/delegated-budgets/me"
    assert client.get(url, headers=auth(token)).json()["pool_category_id"] == pool["id"]
    grant = client.put(f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_categories"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [games["id"]],
    })
    assert grant.status_code == 200
    response = client.get(url, headers=auth(token))
    assert response.status_code == 200 and response.json() is None
