"""Locked server contract for category Targets.

Targets are planning metadata, not money. These tests fix the behavior the
production Targets UI depends on: type round-trips, recommendation/underfunded
math, deny-by-default authorization and scope isolation, the accounting
invariants (a target never creates/moves money), delete semantics, validation,
and deterministic (last-writer-wins) upsert for this non-monetary metadata.
"""

from app.models import AllocationPosting, CategoryTarget, Membership

from .conftest import auth
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_delegated_access import add_child


def target_url(budget_id, category_id):
    return f"/api/v1/budgets/{budget_id}/categories/{category_id}/target"


def postings_sum(session_factory, budget_id):
    with session_factory() as db:
        return sum(p.amount_minor for p in db.query(AllocationPosting).filter_by(budget_id=budget_id))


def summary(client, token, budget_id, month="2026-09-01"):
    return client.get(f"/api/v1/budgets/{budget_id}/months/{month}", headers=auth(token)).json()


def grant_scoped_planner(client, owner_token, budget_id, user_id, account_id, category_ids, capabilities):
    assert client.put(
        f"/api/v1/budgets/{budget_id}/grants", headers=auth(owner_token),
        json={"user_id": user_id, "permission": "contribute"},
    ).status_code == 200
    assert client.put(
        f"/api/v1/budgets/{budget_id}/access/{user_id}", headers=auth(owner_token),
        json={
            "capabilities": capabilities,
            "restrict_accounts": True, "account_ids": [account_id],
            "restrict_categories": True, "category_ids": category_ids,
        },
    ).status_code == 200


# ---------------------------------------------------------------------------
# Target types and round-trip
# ---------------------------------------------------------------------------

def test_all_target_types_round_trip(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, monthly = create_budget_structure(client, owner_token, budget["id"])
    savings = add_category(client, owner_token, budget["id"], "Goals", "Emergency")
    by_date = add_category(client, owner_token, budget["id"], "Goals", "Vacation")
    recurring = add_category(client, owner_token, budget["id"], "True Expenses", "Insurance")

    cases = [
        (monthly["id"], {"target_type": "monthly_funding", "target_amount_minor": 40000}),
        (savings["id"], {"target_type": "savings_balance", "target_amount_minor": 1500000, "minimum_contribution_minor": 5000}),
        (by_date["id"], {"target_type": "target_by_date", "target_amount_minor": 600000, "target_date": "2027-06-01", "priority": 70}),
        (recurring["id"], {"target_type": "recurring_expense", "target_amount_minor": 120000, "target_date": "2027-01-01", "recurrence_months": 12}),
    ]
    for category_id, body in cases:
        put = client.put(target_url(budget["id"], category_id), headers=auth(owner_token), json=body)
        assert put.status_code == 200, put.text
        got = client.get(target_url(budget["id"], category_id), headers=auth(owner_token))
        assert got.status_code == 200, got.text
        row = got.json()
        for key, value in body.items():
            assert row[key] == value, (key, row.get(key), value)
        assert row["is_active"] is True


def test_recommendation_math_by_type_is_explainable(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, monthly = create_budget_structure(client, owner_token, budget["id"])
    savings = add_category(client, owner_token, budget["id"], "Goals", "Emergency")
    fund(client, owner_token, budget["id"], account["id"], amount=500000)

    # Monthly funding: recommend the full amount, underfunded until assigned.
    client.put(target_url(budget["id"], monthly["id"]), headers=auth(owner_token),
               json={"target_type": "monthly_funding", "target_amount_minor": 40000, "minimum_contribution_minor": 10000})
    rows = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows[monthly["id"]]["recommended_contribution_minor"] == 40000
    assert rows[monthly["id"]]["underfunded_minor"] == 40000

    client.put(f"/api/v1/budgets/{budget['id']}/categories/{monthly['id']}/assignment",
               headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 25000})
    rows = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows[monthly["id"]]["recommended_contribution_minor"] == 40000
    assert rows[monthly["id"]]["underfunded_minor"] == 15000  # 40000 - 25000

    # Savings balance: recommend the remaining gap to reach the balance.
    client.put(target_url(budget["id"], savings["id"]), headers=auth(owner_token),
               json={"target_type": "savings_balance", "target_amount_minor": 100000})
    rows = {r["category_id"]: r for r in summary(client, owner_token, budget["id"])["categories"]}
    assert rows[savings["id"]]["recommended_contribution_minor"] == 100000  # nothing saved yet


# ---------------------------------------------------------------------------
# Accounting invariants: targets are metadata, never money
# ---------------------------------------------------------------------------

def test_target_lifecycle_never_creates_or_moves_money(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
               headers=auth(owner_token), json={"month": "2026-09-01", "assigned_minor": 30000})

    before = summary(client, owner_token, budget["id"])
    before_postings = postings_sum(session_factory, budget["id"])
    account_balance = client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
    txn_count = len(client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json())

    def assert_money_unchanged(tag):
        now = summary(client, owner_token, budget["id"])
        assert now["ready_to_assign_minor"] == before["ready_to_assign_minor"], tag
        assert now["allocation_version"] == before["allocation_version"], tag
        assert now["categories"][0]["assigned_minor"] == before["categories"][0]["assigned_minor"], tag
        assert postings_sum(session_factory, budget["id"]) == before_postings, tag
        bal = client.get(f"/api/v1/budgets/{budget['id']}/accounts/{account['id']}/balance", headers=auth(owner_token)).json()
        assert bal == account_balance, tag
        assert len(client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()) == txn_count, tag

    # Create a large future target: must not create spendable money.
    client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
               json={"target_type": "target_by_date", "target_amount_minor": 5000000, "target_date": "2028-01-01"})
    assert_money_unchanged("create")
    # Edit it.
    client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
               json={"target_type": "monthly_funding", "target_amount_minor": 90000})
    assert_money_unchanged("edit")
    # Deactivate (snooze) it.
    client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
               json={"target_type": "monthly_funding", "target_amount_minor": 90000, "is_active": False})
    assert_money_unchanged("deactivate")
    # Delete it.
    assert client.delete(target_url(budget["id"], category["id"]), headers=auth(owner_token)).status_code == 204
    assert_money_unchanged("delete")


def test_recommendation_alone_does_not_assign(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    fund(client, owner_token, budget["id"], account["id"], amount=200000)
    client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
               json={"target_type": "monthly_funding", "target_amount_minor": 50000})
    row = summary(client, owner_token, budget["id"])["categories"][0]
    assert row["recommended_contribution_minor"] == 50000
    assert row["assigned_minor"] == 0            # recommendation is not assignment
    assert row["available_minor"] == 0
    assert summary(client, owner_token, budget["id"])["ready_to_assign_minor"] == 200000


# ---------------------------------------------------------------------------
# Delete semantics
# ---------------------------------------------------------------------------

def test_delete_target_is_idempotent_contract(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
               json={"target_type": "monthly_funding", "target_amount_minor": 40000})
    assert client.delete(target_url(budget["id"], category["id"]), headers=auth(owner_token)).status_code == 204
    assert client.get(target_url(budget["id"], category["id"]), headers=auth(owner_token)).status_code == 404
    # Deleting again (none present) is 404, not 500.
    assert client.delete(target_url(budget["id"], category["id"]), headers=auth(owner_token)).status_code == 404
    # Re-creating after delete works.
    assert client.put(target_url(budget["id"], category["id"]), headers=auth(owner_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 12000}).status_code == 200


# ---------------------------------------------------------------------------
# Authorization and privacy: deny by default
# ---------------------------------------------------------------------------

def test_target_management_requires_manage_planning_and_respects_scope(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, visible = create_budget_structure(client, owner_token, budget["id"])
    hidden = add_category(client, owner_token, budget["id"], "Private", "Parent Only")
    member_id, member_token = add_child(session_factory, client)

    # Member without manage_planning cannot create or delete a target.
    grant_scoped_planner(
        client, owner_token, budget["id"], member_id, account["id"], [visible["id"]],
        capabilities=["view_budget", "view_accounts", "view_categories", "view_transactions", "create_transaction"],
    )
    assert client.put(target_url(budget["id"], visible["id"]), headers=auth(member_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 403
    assert client.delete(target_url(budget["id"], visible["id"]), headers=auth(member_token)).status_code == 403

    # With manage_planning but restricted scope: can target visible, cannot touch hidden.
    grant_scoped_planner(
        client, owner_token, budget["id"], member_id, account["id"], [visible["id"]],
        capabilities=["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"],
    )
    assert client.put(target_url(budget["id"], visible["id"]), headers=auth(member_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 200
    # Hidden category: create, read, and delete all 404 (indistinguishable from nonexistent, no leak).
    assert client.put(target_url(budget["id"], hidden["id"]), headers=auth(member_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 404
    assert client.get(target_url(budget["id"], hidden["id"]), headers=auth(member_token)).status_code == 404
    assert client.delete(target_url(budget["id"], hidden["id"]), headers=auth(member_token)).status_code == 404


def test_target_cannot_target_category_from_another_budget(client, owner_token, session_factory):
    budget_a = create_budget(client, owner_token, session_factory, name="A")
    budget_b = create_budget(client, owner_token, session_factory, name="B")
    _, cat_a = create_budget_structure(client, owner_token, budget_a["id"])
    _, cat_b = create_budget_structure(client, owner_token, budget_b["id"])
    # Using budget A path with budget B category id must 404 (cross-budget isolation).
    assert client.put(target_url(budget_a["id"], cat_b["id"]), headers=auth(owner_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 404
    assert client.get(target_url(budget_a["id"], cat_b["id"]), headers=auth(owner_token)).status_code == 404


def test_deactivated_member_cannot_mutate_targets(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, visible = create_budget_structure(client, owner_token, budget["id"])
    member_id, member_token = add_child(session_factory, client)
    grant_scoped_planner(
        client, owner_token, budget["id"], member_id, account["id"], [visible["id"]],
        capabilities=["view_budget", "view_accounts", "view_categories", "view_transactions", "manage_planning"],
    )
    assert client.put(target_url(budget["id"], visible["id"]), headers=auth(member_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 200
    # Deactivate the membership; existing target history is preserved but new mutations are denied.
    with session_factory() as db:
        membership = db.query(Membership).filter_by(user_id=member_id).one()
        membership.is_active = False
        db.commit()
    assert client.put(target_url(budget["id"], visible["id"]), headers=auth(member_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 99999}).status_code == 404
    assert client.delete(target_url(budget["id"], visible["id"]), headers=auth(member_token)).status_code == 404
    # Owner still sees the untouched target (history preserved).
    row = client.get(target_url(budget["id"], visible["id"]), headers=auth(owner_token)).json()
    assert row["target_amount_minor"] == 40000


# ---------------------------------------------------------------------------
# Validation and boundaries
# ---------------------------------------------------------------------------

def test_target_validation_rejects_impossible_inputs(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    url = target_url(budget["id"], category["id"])

    bad_bodies = [
        {"target_type": "monthly_funding", "target_amount_minor": -100},          # negative amount
        {"target_type": "monthly_funding", "target_amount_minor": 0},             # zero amount
        {"target_type": "monthly_funding", "target_amount_minor": 2**63},         # over Int64 max
        {"target_type": "not_a_type", "target_amount_minor": 100},                # invalid enum
        {"target_type": "target_by_date", "target_amount_minor": 100, "target_date": "not-a-date"},  # malformed date
        {"target_type": "target_by_date", "target_amount_minor": 100},            # missing required date
        {"target_type": "recurring_expense", "target_amount_minor": 100, "target_date": "2027-01-01"},  # missing recurrence
        {"target_type": "monthly_funding", "target_amount_minor": 100, "priority": 200},  # priority out of range
        {"target_type": "monthly_funding", "target_amount_minor": 100, "minimum_contribution_minor": -1},  # negative min
    ]
    for body in bad_bodies:
        assert client.put(url, headers=auth(owner_token), json=body).status_code == 422, body

    # Nonexistent category id (well-formed request) -> 404, not 422/500.
    assert client.put(target_url(budget["id"], "does-not-exist"), headers=auth(owner_token),
                      json={"target_type": "monthly_funding", "target_amount_minor": 100}).status_code == 404


def test_target_upsert_is_deterministic_last_writer_wins(client, owner_token, session_factory):
    """Targets are non-monetary metadata: upsert is idempotent LWW (one row per category)."""
    budget = create_budget(client, owner_token, session_factory)
    _, category = create_budget_structure(client, owner_token, budget["id"])
    url = target_url(budget["id"], category["id"])
    assert client.put(url, headers=auth(owner_token), json={"target_type": "monthly_funding", "target_amount_minor": 40000}).status_code == 200
    assert client.put(url, headers=auth(owner_token), json={"target_type": "savings_balance", "target_amount_minor": 90000}).status_code == 200
    row = client.get(url, headers=auth(owner_token)).json()
    assert row["target_type"] == "savings_balance"
    assert row["target_amount_minor"] == 90000
    with session_factory() as db:
        assert db.query(CategoryTarget).filter_by(category_id=category["id"]).count() == 1
