"""Locked server contract for scheduled / recurring transactions.

Fundamental invariant: a scheduled transaction is a future obligation. It may
feed forecast/recommendation output, but it must never mutate actual account
balances, category activity, allocations, credit-card reserves, or spendable
cash until explicitly realized into an actual transaction. Realization reuses
the same accounting engine as manual entry and cannot double-post an occurrence.
"""

from datetime import date, timedelta

from app.models import AllocationPosting, Membership, Transaction
from app.planning import next_occurrence

from .conftest import auth
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_delegated_access import add_child


PAST = "2026-09-01"  # <= test clock (>= 2026-09-05), so realizable
def future(days=20): return (date.today() + timedelta(days=days)).isoformat()
def horizon(days=60): return (date.today() + timedelta(days=days)).isoformat()


def sched_url(b): return f"/api/v1/budgets/{b}/scheduled-transactions"
def item_url(b, s): return f"/api/v1/budgets/{b}/scheduled-transactions/{s}"
def realize_url(b, s): return f"/api/v1/budgets/{b}/scheduled-transactions/{s}/realize"


def create_schedule(client, token, budget_id, **body):
    return client.post(sched_url(budget_id), headers=auth(token), json=body)


def summary(client, token, b, month="2026-09-01"):
    return client.get(f"/api/v1/budgets/{b}/months/{month}", headers=auth(token)).json()


def balance(client, token, b, account_id):
    return client.get(f"/api/v1/budgets/{b}/accounts/{account_id}/balance", headers=auth(token)).json()


def txn_count(client, token, b):
    return len(client.get(f"/api/v1/budgets/{b}/transactions", headers=auth(token)).json())


def postings_sum(session_factory, b):
    with session_factory() as db:
        return sum(p.amount_minor for p in db.query(AllocationPosting).filter_by(budget_id=b))


def grant_planner(client, owner_token, b, user_id, account_id, category_ids, capabilities):
    assert client.put(f"/api/v1/budgets/{b}/grants", headers=auth(owner_token),
                      json={"user_id": user_id, "permission": "contribute"}).status_code == 200
    assert client.put(f"/api/v1/budgets/{b}/access/{user_id}", headers=auth(owner_token),
                      json={"capabilities": capabilities, "restrict_accounts": True, "account_ids": [account_id],
                            "restrict_categories": True, "category_ids": category_ids}).status_code == 200


# ---------------------------------------------------------------------------
# CRUD round-trip
# ---------------------------------------------------------------------------

def test_schedule_crud_round_trip(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                              name="Netflix", amount_minor=-1599, next_date=future(), recurrence_unit="months", interval_count=1, memo="stream")
    assert created.status_code == 201, created.text
    sid = created.json()["id"]
    assert created.json()["is_active"] is True
    assert created.json()["last_realized_on"] is None

    listed = client.get(sched_url(budget["id"]), headers=auth(owner_token)).json()
    assert sid in {s["id"] for s in listed}

    updated = client.put(item_url(budget["id"], sid), headers=auth(owner_token),
                         json={"account_id": account["id"], "category_id": category["id"], "name": "Netflix Premium",
                               "amount_minor": -1999, "next_date": future(30), "recurrence_unit": "months", "interval_count": 1, "is_active": True})
    assert updated.status_code == 200, updated.text
    assert updated.json()["amount_minor"] == -1999
    assert updated.json()["name"] == "Netflix Premium"

    # Disable via update.
    assert client.put(item_url(budget["id"], sid), headers=auth(owner_token),
                      json={"account_id": account["id"], "category_id": category["id"], "name": "Netflix Premium",
                            "amount_minor": -1999, "next_date": future(30), "recurrence_unit": "months", "is_active": False}).status_code == 200
    assert sid not in {s["id"] for s in client.get(sched_url(budget["id"]), headers=auth(owner_token)).json()}  # list filters inactive

    assert client.delete(item_url(budget["id"], sid), headers=auth(owner_token)).status_code == 204
    assert client.delete(item_url(budget["id"], sid), headers=auth(owner_token)).status_code == 404


# ---------------------------------------------------------------------------
# Actual-vs-forecast invariants (before realization)
# ---------------------------------------------------------------------------

def test_scheduled_items_do_not_touch_actuals_before_realization(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
               headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 30000})

    before_summary = summary(client, owner_token, budget["id"])
    before_balance = balance(client, owner_token, budget["id"], account["id"])
    before_count = txn_count(client, owner_token, budget["id"])
    before_postings = postings_sum(session_factory, budget["id"])

    # Schedule a large future expense AND future income; even an overdue (PAST) one must not post.
    create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                    name="Big future bill", amount_minor=-5000000, next_date=future(), recurrence_unit="months")
    create_schedule(client, owner_token, budget["id"], account_id=account["id"], name="Future paycheck",
                    amount_minor=900000, next_date=future(), recurrence_unit="months")
    create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                    name="Overdue bill", amount_minor=-40000, next_date=PAST, recurrence_unit="months")

    after_summary = summary(client, owner_token, budget["id"])
    assert after_summary["ready_to_assign_minor"] == before_summary["ready_to_assign_minor"]
    assert after_summary["allocation_version"] == before_summary["allocation_version"]
    assert after_summary["categories"][0]["activity_minor"] == before_summary["categories"][0]["activity_minor"]
    assert after_summary["categories"][0]["available_minor"] == before_summary["categories"][0]["available_minor"]
    assert balance(client, owner_token, budget["id"], account["id"]) == before_balance
    assert txn_count(client, owner_token, budget["id"]) == before_count
    assert postings_sum(session_factory, budget["id"]) == before_postings


def test_scheduled_income_is_forecast_only_not_spendable(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    rta_before = summary(client, owner_token, budget["id"])["ready_to_assign_minor"]

    create_schedule(client, owner_token, budget["id"], account_id=account["id"], name="Salary",
                    amount_minor=500000, next_date=future(10), recurrence_unit="once")

    # RTA / spendable unchanged.
    assert summary(client, owner_token, budget["id"])["ready_to_assign_minor"] == rta_before
    # Forecast shows the future inflow as projected, distinct from actual.
    fc = client.get(f"/api/v1/budgets/{budget['id']}/forecast?through={horizon()}", headers=auth(owner_token)).json()
    assert fc["projected_total_on_budget_minor"] == fc["actual_total_on_budget_minor"] + 500000
    assert any(o["amount_minor"] == 500000 for o in fc["occurrences"])


def test_disabling_and_deleting_schedule_updates_forecast(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, _ = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    created = create_schedule(client, owner_token, budget["id"], account_id=account["id"], name="Salary",
                              amount_minor=500000, next_date=future(10), recurrence_unit="once")
    sid = created.json()["id"]
    fc = client.get(f"/api/v1/budgets/{budget['id']}/forecast?through={horizon()}", headers=auth(owner_token)).json()
    assert fc["projected_total_on_budget_minor"] == fc["actual_total_on_budget_minor"] + 500000
    # Delete removes it from the forecast.
    assert client.delete(item_url(budget["id"], sid), headers=auth(owner_token)).status_code == 204
    fc = client.get(f"/api/v1/budgets/{budget['id']}/forecast?through={horizon()}", headers=auth(owner_token)).json()
    assert fc["projected_total_on_budget_minor"] == fc["actual_total_on_budget_minor"]


# ---------------------------------------------------------------------------
# Realization + idempotency
# ---------------------------------------------------------------------------

def test_realization_creates_exactly_one_transaction_and_advances(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
               headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 50000})
    created = create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                              name="Rent", amount_minor=-40000, next_date=PAST, recurrence_unit="months")
    sid = created.json()["id"]
    before_count = txn_count(client, owner_token, budget["id"])

    realized = client.post(realize_url(budget["id"], sid), headers=auth(owner_token))
    assert realized.status_code == 200, realized.text
    body = realized.json()
    assert len(body["transaction_ids"]) == 1
    assert body["realized_on"] == PAST
    assert body["is_active"] is True
    assert body["next_date"] is not None and body["next_date"] > PAST  # advanced one month

    # Exactly one actual transaction created, with lineage.
    assert txn_count(client, owner_token, budget["id"]) == before_count + 1
    with session_factory() as db:
        txn = db.get(Transaction, body["transaction_ids"][0])
        assert txn.scheduled_transaction_id == sid
        assert txn.amount_minor == -40000
    # Category activity moved by the realized amount, exactly once.
    rows = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows[category["id"]]["activity_minor"] == -40000

    # Re-realizing does not double-post: the occurrence already advanced to a future date.
    again = client.post(realize_url(budget["id"], sid), headers=auth(owner_token))
    assert again.status_code == 422
    assert txn_count(client, owner_token, budget["id"]) == before_count + 1


def test_once_schedule_deactivates_after_realization_and_cannot_repeat(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    created = create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                              name="One-off", amount_minor=-5000, next_date=PAST, recurrence_unit="once")
    sid = created.json()["id"]
    first = client.post(realize_url(budget["id"], sid), headers=auth(owner_token))
    assert first.status_code == 200
    assert first.json()["is_active"] is False
    assert first.json()["next_date"] is None
    # Inactive schedule cannot be realized again.
    assert client.post(realize_url(budget["id"], sid), headers=auth(owner_token)).status_code == 409


def test_cannot_realize_before_due(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    created = create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                              name="Future", amount_minor=-5000, next_date=future(15), recurrence_unit="months")
    assert client.post(realize_url(budget["id"], created.json()["id"]), headers=auth(owner_token)).status_code == 422


# ---------------------------------------------------------------------------
# Credit cards & transfers
# ---------------------------------------------------------------------------

def test_scheduled_credit_purchase_only_affects_card_at_realization(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    card = create_credit_card(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
               headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 50000})
    created = create_schedule(client, owner_token, budget["id"], account_id=card["id"], category_id=groceries["id"],
                              name="Groceries", amount_minor=-30000, next_date=PAST, recurrence_unit="months")
    sid = created.json()["id"]

    # Before realization: no card liability, no reserve.
    assert balance(client, owner_token, budget["id"], card["id"])["working_balance_minor"] == 0
    rows = {r["name"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows["Visa Payment"]["available_minor"] == 0
    assert rows["Groceries"]["available_minor"] == 50000

    assert client.post(realize_url(budget["id"], sid), headers=auth(owner_token)).status_code == 200
    # After: normal credit engine ran exactly once.
    assert balance(client, owner_token, budget["id"], card["id"])["working_balance_minor"] == -30000
    rows = {r["name"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows["Groceries"]["available_minor"] == 20000
    assert rows["Visa Payment"]["available_minor"] == 30000


def test_scheduled_transfer_moves_no_money_until_realized(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, _ = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Savings", "account_type": "savings"}).json()
    fund(client, owner_token, budget["id"], checking["id"], amount=100000)
    created = create_schedule(client, owner_token, budget["id"], account_id=checking["id"],
                              destination_account_id=savings["id"], name="To savings", amount_minor=25000,
                              next_date=PAST, recurrence_unit="months")
    sid = created.json()["id"]
    rta_before = summary(client, owner_token, budget["id"])["ready_to_assign_minor"]

    # Before: no movement.
    assert balance(client, owner_token, budget["id"], checking["id"])["working_balance_minor"] == 100000
    assert balance(client, owner_token, budget["id"], savings["id"])["working_balance_minor"] == 0

    realized = client.post(realize_url(budget["id"], sid), headers=auth(owner_token))
    assert realized.status_code == 200
    assert len(realized.json()["transaction_ids"]) == 2
    # After: money moved location, total cash and RTA unchanged (no income/spending).
    assert balance(client, owner_token, budget["id"], checking["id"])["working_balance_minor"] == 75000
    assert balance(client, owner_token, budget["id"], savings["id"])["working_balance_minor"] == 25000
    assert summary(client, owner_token, budget["id"])["ready_to_assign_minor"] == rta_before
    # No double realization.
    assert client.post(realize_url(budget["id"], sid), headers=auth(owner_token)).status_code == 422


# ---------------------------------------------------------------------------
# Recurrence correctness (pure next_occurrence)
# ---------------------------------------------------------------------------

def test_recurrence_boundaries():
    d = date
    assert next_occurrence(d(2026, 1, 15), "months", 1) == d(2026, 2, 15)
    assert next_occurrence(d(2026, 1, 31), "months", 1) == d(2026, 2, 28)   # clamp to Feb (non-leap)
    assert next_occurrence(d(2028, 1, 31), "months", 1) == d(2028, 2, 29)   # leap year
    assert next_occurrence(d(2026, 1, 31), "months", 3) == d(2026, 4, 30)   # 30-day month clamp
    assert next_occurrence(d(2026, 9, 5), "weeks", 1) == d(2026, 9, 12)
    assert next_occurrence(d(2026, 9, 5), "weeks", 2) == d(2026, 9, 19)
    assert next_occurrence(d(2028, 2, 29), "years", 1) == d(2029, 2, 28)    # leap-day annual clamp
    assert next_occurrence(d(2026, 9, 5), "days", 10) == d(2026, 9, 15)
    assert next_occurrence(d(2026, 9, 5), "once", 1) is None


# ---------------------------------------------------------------------------
# Authorization / scope / privacy
# ---------------------------------------------------------------------------

def test_schedule_management_requires_manage_planning_and_realize_requires_create(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    member_id, member_token = add_child(session_factory, client)
    # view-only + create_transaction, but NOT manage_planning.
    grant_planner(client, owner_token, budget["id"], member_id, account["id"], [category["id"]],
                  ["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction"])
    assert create_schedule(client, member_token, budget["id"], account_id=account["id"],
                           category_id=category["id"], name="x", amount_minor=-1000, next_date=PAST,
                           recurrence_unit="months").status_code == 403
    # Owner creates a schedule; member without manage_planning cannot edit/delete it.
    sid = create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                          name="Rent", amount_minor=-1000, next_date=PAST, recurrence_unit="months").json()["id"]
    assert client.delete(item_url(budget["id"], sid), headers=auth(member_token)).status_code == 403
    # But a member WITH create_transaction may realize a due occurrence in their scope.
    assert client.post(realize_url(budget["id"], sid), headers=auth(member_token)).status_code == 200


def test_realization_rechecks_scope_after_permission_revoked(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    other = add_category(client, owner_token, budget["id"], "Private", "Parent Only")
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    member_id, member_token = add_child(session_factory, client)
    grant_planner(client, owner_token, budget["id"], member_id, account["id"], [category["id"]],
                  ["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction", "manage_planning"])
    sid = create_schedule(client, member_token, budget["id"], account_id=account["id"], category_id=category["id"],
                          name="Rent", amount_minor=-1000, next_date=PAST, recurrence_unit="months").json()["id"]
    # Owner revokes the member's access to the category the schedule targets.
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token),
                      json={"capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction", "manage_planning"],
                            "restrict_accounts": True, "account_ids": [account["id"]],
                            "restrict_categories": True, "category_ids": [other["id"]]}).status_code == 200
    # Realization must re-check scope now, not trust creation-time authority.
    assert client.post(realize_url(budget["id"], sid), headers=auth(member_token)).status_code == 422


def test_deactivated_member_and_cross_budget_are_denied(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    member_id, member_token = add_child(session_factory, client)
    grant_planner(client, owner_token, budget["id"], member_id, account["id"], [category["id"]],
                  ["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction", "manage_planning"])
    sid = create_schedule(client, member_token, budget["id"], account_id=account["id"], category_id=category["id"],
                          name="Rent", amount_minor=-1000, next_date=future(), recurrence_unit="months").json()["id"]
    with session_factory() as db:
        m = db.query(Membership).filter_by(user_id=member_id).one()
        m.is_active = False
        db.commit()
    assert client.delete(item_url(budget["id"], sid), headers=auth(member_token)).status_code == 404
    # Cross-budget id isolation.
    other_budget = create_budget(client, owner_token, session_factory, name="Other")
    assert client.get(item_url(other_budget["id"], sid), headers=auth(owner_token)).status_code in {404, 405}
    assert client.delete(item_url(other_budget["id"], sid), headers=auth(owner_token)).status_code == 404


def test_scheduling_creates_no_allocations_and_expands_no_authority(client, owner_token, session_factory):
    """Delegated invariant proxy: scheduling is metadata; it posts nothing to the ledger."""
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=100000)
    before = postings_sum(session_factory, budget["id"])
    create_schedule(client, owner_token, budget["id"], account_id=account["id"], category_id=category["id"],
                    name="Big", amount_minor=-300000, next_date=future(), recurrence_unit="months")
    create_schedule(client, owner_token, budget["id"], account_id=account["id"], name="Income",
                    amount_minor=300000, next_date=future(), recurrence_unit="months")
    assert postings_sum(session_factory, budget["id"]) == before


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def test_schedule_validation_rejects_impossible_inputs(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Savings", "account_type": "savings"}).json()

    def status_for(body):
        return client.post(sched_url(budget["id"]), headers=auth(owner_token), json=body).status_code

    base = {"account_id": account["id"], "name": "x", "next_date": PAST, "recurrence_unit": "months"}
    assert status_for({**base, "amount_minor": 0}) == 422                                   # zero amount
    assert status_for({**base, "amount_minor": 2**63}) == 422                               # over Int64
    assert status_for({**base, "amount_minor": -1000, "recurrence_unit": "fortnights"}) == 422  # bad enum
    assert status_for({**base, "amount_minor": -1000, "next_date": "not-a-date"}) == 422    # malformed date
    assert status_for({**base, "amount_minor": -1000, "interval_count": 0}) == 422          # non-positive interval
    # transfer with a category is rejected.
    assert status_for({"account_id": account["id"], "destination_account_id": savings["id"], "category_id": category["id"],
                       "name": "x", "amount_minor": 5000, "next_date": PAST, "recurrence_unit": "months"}) == 422
    # transfer to same account.
    assert status_for({"account_id": account["id"], "destination_account_id": account["id"], "name": "x",
                       "amount_minor": 5000, "next_date": PAST, "recurrence_unit": "months"}) == 422
    # transfer with negative amount.
    assert status_for({"account_id": account["id"], "destination_account_id": savings["id"], "name": "x",
                       "amount_minor": -5000, "next_date": PAST, "recurrence_unit": "months"}) == 422
    # missing/nonexistent account.
    assert status_for({"account_id": "nope", "amount_minor": -1000, "name": "x", "next_date": PAST, "recurrence_unit": "months"}) == 422
    # category on a tracking account.
    tracking = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                           json={"name": "Brokerage", "account_type": "tracking", "is_on_budget": False}).json()
    assert status_for({"account_id": tracking["id"], "category_id": category["id"], "amount_minor": -1000,
                       "name": "x", "next_date": PAST, "recurrence_unit": "months"}) == 422
