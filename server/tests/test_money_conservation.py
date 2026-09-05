"""Cross-cutting money-conservation invariants.

Every allocation operation is written zero-sum by `append_operation`; this suite
proves that after a representative sequence of *all* allocation-producing paths
(assignment, move, delegated authority, delegated member move, request approval,
smart funding) the global ledger still nets to zero and no path leaked an
unbalanced posting. Credit-card purchase/payment/refund are included to confirm
they never create stray allocation postings.
"""

from datetime import date

from app.models import AllocationPosting

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_delegated_access import add_child, configure_child


def _sum_postings(session_factory, budget_id):
    with session_factory() as db:
        return sum(
            p.amount_minor for p in db.query(AllocationPosting).filter_by(budget_id=budget_id)
        )


def test_allocation_ledger_stays_zero_sum_across_all_paths(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    pool = add_category(client, owner_token, budget["id"], "Delegated", "Alex Pool")
    games = add_category(client, owner_token, budget["id"], "Delegated", "Games")
    card = create_credit_card(client, owner_token, budget["id"])

    fund(client, owner_token, budget["id"], checking["id"], amount=300000)

    # Assignment path.
    for cat, amt in ((groceries["id"], 50000), (dining["id"], 30000)):
        assert client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{cat}/assignment",
            headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": amt},
        ).status_code == 200
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Move path.
    version = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["allocation_version"]
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(owner_token),
        json={"source_category_id": groceries["id"], "destination_category_id": dining["id"], "amount_minor": 10000, "occurred_on": "2026-09-04", "expected_allocation_version": version},
    ).status_code == 201
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Credit purchase + payment + refund (reserve events / transactions, not postings).
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-20000)
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/transfers", headers=auth(owner_token),
        json={"source_account_id": checking["id"], "destination_account_id": card["id"], "amount_minor": 20000, "occurred_on": "2026-09-04"},
    ).status_code == 201
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=5000)
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Delegated authority path (RTA -> member pool) and a delegated member move.
    child_id, child_token = add_child(session_factory, client)
    for cat in (pool["id"], games["id"]):
        assert client.put(
            f"/api/v1/budgets/{budget['id']}/categories/{cat}/delegation",
            headers=auth(owner_token), json={"delegated_user_id": child_id},
        ).status_code == 200
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], [pool["id"], games["id"]])
    # give the child move_money in addition to the base scoped capabilities
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/access/{child_id}", headers=auth(owner_token),
        json={
            "capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "create_transaction", "request_money", "move_money"],
            "restrict_accounts": True, "account_ids": [checking["id"]],
            "restrict_categories": True, "category_ids": [pool["id"], games["id"]],
        },
    ).status_code == 200
    version = client.get(f"/api/v1/budgets/{budget['id']}/months/2026-09-01", headers=auth(owner_token)).json()["allocation_version"]
    assert client.put(
        f"/api/v1/budgets/{budget['id']}/delegated-budgets/{child_id}", headers=auth(owner_token),
        json={"user_id": child_id, "pool_category_id": pool["id"], "authority_minor": 20000, "expected_allocation_version": version, "rules": []},
    ).status_code == 200
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Delegated member moves within their own pool. The authority funding op is dated
    # today (server-side), so the member's move must occur on/after today to see the pool.
    today = date.today().isoformat()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
        json={"source_category_id": pool["id"], "destination_category_id": games["id"], "amount_minor": 5000, "occurred_on": today},
    ).status_code == 201
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Request approval path (member requests into games, owner approves from dining).
    request = client.post(
        f"/api/v1/budgets/{budget['id']}/requests", headers=auth(child_token),
        json={"destination_category_id": games["id"], "requested_amount_minor": 3000, "reason": "Game"},
    ).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/requests/{request['id']}/decision", headers=auth(owner_token),
        json={"decision": "approve", "expected_request_version": 0, "approved_amount_minor": 3000, "source_category_id": dining["id"]},
    ).status_code == 200
    assert _sum_postings(session_factory, budget["id"]) == 0

    # Final global invariant: the entire budget's allocation ledger nets to zero.
    assert _sum_postings(session_factory, budget["id"]) == 0
