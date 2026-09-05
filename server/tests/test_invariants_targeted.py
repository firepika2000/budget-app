"""Targeted financial-invariant regressions that complement the seeded harness.

These cover invariants that are clearer as deterministic scenarios than as random
sequences: request-approval terminal-state safety, delegated-authority
conservation across reallocations, credit-card payment-reserve explainability,
and month rollover not creating current cash.
"""

from sqlalchemy import select

from app.models import AllocationPosting, Category, CreditCardReserveEvent

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card, category_rows
from .test_delegated_access import add_child, configure_child, _delegate_with_pool

MONTH = "2026-09-01"


def summary(client, token, b, month=MONTH):
    return client.get(f"/api/v1/budgets/{b}/months/{month}", headers=auth(token)).json()


# ---------------------------------------------------------------------------
# Request / approval terminal-state safety (no money after reject/cancel)
# ---------------------------------------------------------------------------

def test_approve_after_reject_or_cancel_creates_no_money(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    source = add_category(client, owner_token, budget["id"], "Family", "Pool")
    dest = add_category(client, owner_token, budget["id"], "Delegated", "Child Fun")
    record(client, owner_token, budget["id"], account_id=checking["id"], amount_minor=20000, is_cleared=True)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{source['id']}/assignment",
               headers=auth(owner_token), json={"month": MONTH, "assigned_minor": 20000})
    child_id, child_token = add_child(session_factory, client)
    configure_child(client, owner_token, budget["id"], child_id, checking["id"], dest["id"])

    def postings_sum():
        with session_factory() as db:
            return sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(AllocationPosting.budget_id == budget["id"])).all())

    before = postings_sum()
    before_source = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}[source["id"]]["available_minor"]

    # Rejected request cannot then be approved.
    req = client.post(f"/api/v1/budgets/{budget['id']}/requests", headers=auth(child_token),
                      json={"destination_category_id": dest["id"], "requested_amount_minor": 5000, "reason": "x"}).json()
    assert client.post(f"/api/v1/budgets/{budget['id']}/requests/{req['id']}/decision", headers=auth(owner_token),
                       json={"decision": "reject", "expected_request_version": 0}).status_code == 200
    assert client.post(f"/api/v1/budgets/{budget['id']}/requests/{req['id']}/decision", headers=auth(owner_token),
                       json={"decision": "approve", "expected_request_version": 1, "approved_amount_minor": 5000, "source_category_id": source["id"]}).status_code == 409

    # Cancelled request cannot then be approved.
    req2 = client.post(f"/api/v1/budgets/{budget['id']}/requests", headers=auth(child_token),
                       json={"destination_category_id": dest["id"], "requested_amount_minor": 4000, "reason": "y"}).json()
    assert client.post(f"/api/v1/budgets/{budget['id']}/requests/{req2['id']}/cancel", headers=auth(child_token),
                       json={"expected_request_version": 0}).status_code == 200
    assert client.post(f"/api/v1/budgets/{budget['id']}/requests/{req2['id']}/decision", headers=auth(owner_token),
                       json={"decision": "approve", "expected_request_version": 1, "approved_amount_minor": 4000, "source_category_id": source["id"]}).status_code == 409

    # No allocation happened; ledger and source unchanged.
    assert postings_sum() == before
    after_source = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}[source["id"]]["available_minor"]
    assert after_source == before_source


# ---------------------------------------------------------------------------
# Delegated authority conservation
# ---------------------------------------------------------------------------

def test_delegated_authority_conserved_across_member_reallocations(client, owner_token, session_factory):
    budget, checking, pool, games, child_id, child_token = _delegate_with_pool(
        client, owner_token, session_factory,
        capabilities=["view_budget", "view_accounts", "view_categories", "view_transactions", "move_money"],
    )
    authority = 20000

    def controlled_allocation():
        with session_factory() as db:
            controlled = set(db.scalars(select(Category.id).where(
                Category.budget_id == budget["id"],
                Category.delegated_user_id == child_id,
            )))
            return sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(
                AllocationPosting.budget_id == budget["id"],
                AllocationPosting.category_id.in_(controlled),
            )).all())

    assert controlled_allocation() == authority  # funded to exactly the authority

    # Several in-sandbox reallocations must each conserve the total controlled allocation.
    for amount in (5000, 3000, 2000):
        r = client.post(f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
                        json={"source_category_id": pool["id"], "destination_category_id": games["id"], "amount_minor": amount, "occurred_on": "2026-09-04"})
        assert r.status_code == 201, r.text
        assert controlled_allocation() == authority

    # Moving more than the pool holds is rejected (cannot exceed authority).
    over = client.post(f"/api/v1/budgets/{budget['id']}/allocation-transfers", headers=auth(child_token),
                       json={"source_category_id": pool["id"], "destination_category_id": games["id"], "amount_minor": 10_000_000, "occurred_on": "2026-09-04"})
    assert over.status_code == 409
    assert controlled_allocation() == authority


# ---------------------------------------------------------------------------
# Credit-card payment reserve explainability
# ---------------------------------------------------------------------------

def test_payment_reserve_is_explainable_from_reserve_events(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    dining = add_category(client, owner_token, budget["id"], "Food", "Dining")
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=200000)
    for cat in (groceries, dining):
        client.put(f"/api/v1/budgets/{budget['id']}/categories/{cat['id']}/assignment",
                   headers=auth(owner_token), json={"month": MONTH, "assigned_minor": 50000})
    # Funded purchases on two categories + a partial refund.
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=-30000)
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=dining["id"], amount_minor=-20000)
    record(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"], amount_minor=8000)

    _, rows = category_rows(client, owner_token, budget["id"])
    payment_available = rows["Visa Payment"]["available_minor"]
    with session_factory() as db:
        payment_category_id = client.get(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token)).json()
        pcid = next(a["payment_category_id"] for a in payment_category_id if a["id"] == card["id"])
        reserve_events = sum(e.amount_minor for e in db.scalars(select(CreditCardReserveEvent).where(
            CreditCardReserveEvent.budget_id == budget["id"],
            CreditCardReserveEvent.payment_category_id == pcid,
        )).all())
        allocated_to_payment = sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(
            AllocationPosting.budget_id == budget["id"], AllocationPosting.category_id == pcid,
        )).all())
    # Reserve position is fully explainable: available == reserve events + explicit allocations.
    assert payment_available == reserve_events + allocated_to_payment
    # And equals net funded purchases (30000 + 20000 - 8000) with no explicit assignment here.
    assert allocated_to_payment == 0
    assert payment_available == 42000


# ---------------------------------------------------------------------------
# Month rollover does not create current cash
# ---------------------------------------------------------------------------

def test_positive_rollover_carries_without_creating_current_cash(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
               headers=auth(owner_token), json={"month": MONTH, "assigned_minor": 40000})
    record(client, owner_token, budget["id"], account_id=checking["id"], category_id=category["id"], amount_minor=-15000)

    sept = summary(client, owner_token, budget["id"], "2026-09-01")
    sept_available = sept["categories"][0]["available_minor"]
    assert sept_available == 25000  # 40000 assigned - 15000 spent

    # Viewing the next month carries the positive Available forward as carried, not as new cash.
    octo = summary(client, owner_token, budget["id"], "2026-10-01")
    octo_row = octo["categories"][0]
    assert octo_row["carried_available_minor"] == 25000
    assert octo_row["assigned_minor"] == 0
    assert octo_row["available_minor"] == 25000
    # RTA reflects real uncategorized cash only (100000 in - 40000 assigned = 60000), unchanged by the view month.
    assert sept["ready_to_assign_minor"] == 60000
    assert octo["ready_to_assign_minor"] == 60000
