from uuid import uuid4
import pytest

from app.models import Reconciliation, Transaction, User
from .conftest import auth
from .test_advanced_ledger import record
from .test_budgeting_api import add_member, create_budget, create_budget_structure


@pytest.mark.parametrize("change", ["offsetting_additions", "metadata", "cleared_set", "cutoff"])
def test_review_token_rejects_changed_set_even_with_same_balance(client, owner_token, session_factory, change):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    row = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100, is_cleared=True)
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}"
    observation = client.get(f"{path}/reconciliation-observation?through_date=2026-09-04", headers=auth(owner_token))
    assert observation.status_code == 200, observation.text
    assert observation.json()["cleared_balance_minor"] == -100
    through = "2026-09-04"
    if change == "offsetting_additions":
        for amount in [50, -50]:
            record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=amount, is_cleared=True)
    elif change == "metadata":
        with session_factory() as db:
            db.get(Transaction, row["id"]).memo = "New reviewed metadata"
            db.commit()
    elif change == "cleared_set":
        replacement = record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=-100)
        with session_factory() as db:
            db.get(Transaction, row["id"]).is_cleared = False
            db.get(Transaction, replacement["id"]).is_cleared = True
            db.commit()
    else:
        through = "2026-09-05"
    current = client.get(f"{path}/reconciliation-observation?through_date={through}", headers=auth(owner_token)).json()
    assert current["cleared_balance_minor"] == -100
    assert current["review_revision"] != observation.json()["review_revision"]
    result = client.post(f"{path}/reconcile", headers=auth(owner_token), json={
        "statement_balance_minor": -100, "through_date": through, "expected_cleared_balance_minor": -100,
        "expected_review_revision": observation.json()["review_revision"], "mutation_operation_id": str(uuid4())})
    assert result.status_code == 409, result.text
    with session_factory() as db:
        assert db.query(Reconciliation).count() == 0


def test_review_token_accepts_exact_observation_and_receipt_retry(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    record(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"], amount_minor=9007199254740993, is_cleared=True)
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}"
    observed = client.get(f"{path}/reconciliation-observation?through_date=2026-09-04", headers=auth(owner_token)).json()
    body = {"statement_balance_minor": observed["cleared_balance_minor"], "expected_cleared_balance_minor": observed["cleared_balance_minor"],
            "through_date": "2026-09-04", "expected_review_revision": observed["review_revision"], "mutation_operation_id": str(uuid4())}
    first = client.post(f"{path}/reconcile", headers=auth(owner_token), json=body)
    assert first.status_code == 200, first.text
    current = client.get(f"{path}/reconciliation-observation?through_date=2026-09-04", headers=auth(owner_token)).json()
    assert current["review_revision"] != observed["review_revision"]
    assert client.post(f"{path}/reconcile", headers=auth(owner_token), json=body).json() == first.json()
    assert client.post(f"{path}/reconcile", headers=auth(owner_token), json={**body, "mutation_operation_id": str(uuid4())}).status_code == 409
    with session_factory() as db:
        assert db.query(Reconciliation).count() == 1


@pytest.mark.parametrize("restriction", ["account", "capability"])
def test_observation_is_actor_bound_and_currently_authorized(client, owner_token, session_factory, restriction):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    token = add_member(session_factory, client, "contribute", budget["id"])
    with session_factory() as db:
        member = db.query(User).filter_by(email="contribute@example.com").one().id
    access = {"capabilities": ["reconcile_account", "view_budget"], "restrict_accounts": False,
              "account_ids": [], "restrict_categories": False, "category_ids": []}
    access_path = f"/api/v1/budgets/{budget['id']}/access/{member}"
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    path = f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}"
    observation_path = f"{path}/reconciliation-observation?through_date=2026-09-04"
    owner = client.get(observation_path, headers=auth(owner_token)).json()
    member_observation = client.get(observation_path, headers=auth(token))
    assert member_observation.status_code == 200, member_observation.text
    assert owner["review_revision"] != member_observation.json()["review_revision"]
    assert client.post(f"{path}/reconcile", headers=auth(token), json={"statement_balance_minor": 0,
        "expected_cleared_balance_minor": 0, "through_date": "2026-09-04",
        "expected_review_revision": owner["review_revision"]}).status_code == 409
    if restriction == "account":
        access["restrict_accounts"] = True
    else:
        access["capabilities"] = ["view_budget"]
    assert client.put(access_path, headers=auth(owner_token), json=access).status_code == 200
    rejected = client.get(observation_path, headers=auth(token))
    assert rejected.status_code == (404 if restriction == "account" else 403)
    assert "review_revision" not in rejected.text
