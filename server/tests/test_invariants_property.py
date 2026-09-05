"""Seeded, property-style money-conservation harness.

Generates a reproducible random sequence of valid monetary operations and, after
every applied step, asserts the global financial invariants. The goal is to make
it hard for a future API/UI change to silently mint, destroy, duplicate, or
misclassify money.

Independent identities checked after each step (computed here, not read back from
the code under test where avoidable):

  I1  Sum of ALL allocation postings == 0                      (ledger balanced)
  I2  server RTA == uncategorized_on_budget_cash + alloc(None)  (RTA is real cash)
  I3  server RTA + assigned_total == uncategorized_on_budget_cash
        (assign/move only shuffle between RTA and categories)
  I4  Sum of transfer-leg amounts == 0                         (transfers conserve cash)
  I5  For every split transaction, sum(split amounts) == parent amount (no penny drift)
  I6  Targets and pre-realization schedules never change I1-I5

On failure the assertion message carries the seed, step index, operation, and the
offending values so a future regression is debuggable.
"""

import random

from sqlalchemy import select

from app.models import (
    Account,
    AllocationPosting,
    Category,
    ScheduledTransaction,
    Transaction,
    TransactionSplit,
)

from .conftest import auth
from .test_advanced_ledger import add_category
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card

MONTH = "2026-09-01"
CASH_TYPES = {"checking", "savings", "cash"}


def summary(client, token, b):
    return client.get(f"/api/v1/budgets/{b}/months/{MONTH}", headers=auth(token)).json()


def independent_state(session_factory, budget_id):
    """Compute conservation quantities directly from stored rows."""
    with session_factory() as db:
        postings = db.scalars(select(AllocationPosting).where(AllocationPosting.budget_id == budget_id)).all()
        alloc_all = sum(p.amount_minor for p in postings)
        alloc_none = sum(p.amount_minor for p in postings if p.category_id is None)
        assigned_total = sum(p.amount_minor for p in postings if p.category_id is not None)
        cash_account_ids = set(db.scalars(select(Account.id).where(
            Account.budget_id == budget_id, Account.is_on_budget.is_(True),
            Account.account_type.in_(tuple(CASH_TYPES)),
        )))
        split_txn_ids = set(db.scalars(select(TransactionSplit.transaction_id)))
        uncategorized_cash = 0
        transfer_leg_total = 0
        split_ok = True
        txns = db.scalars(select(Transaction).where(Transaction.budget_id == budget_id)).all()
        splits_by_txn: dict[str, int] = {}
        for s in db.scalars(select(TransactionSplit)).all():
            splits_by_txn.setdefault(s.transaction_id, 0)
            splits_by_txn[s.transaction_id] += s.amount_minor
        for t in txns:
            if t.transfer_id is not None:
                transfer_leg_total += t.amount_minor
            if (t.account_id in cash_account_ids and t.category_id is None
                    and t.transfer_id is None and t.id not in split_txn_ids):
                uncategorized_cash += t.amount_minor
            if t.id in splits_by_txn and splits_by_txn[t.id] != t.amount_minor:
                split_ok = False
        return {
            "alloc_all": alloc_all,
            "alloc_none": alloc_none,
            "assigned_total": assigned_total,
            "uncategorized_cash": uncategorized_cash,
            "transfer_leg_total": transfer_leg_total,
            "split_ok": split_ok,
        }


def assert_invariants(client, token, session_factory, budget_id, *, seed, step, op, log):
    st = independent_state(session_factory, budget_id)
    rta = summary(client, token, budget_id)["ready_to_assign_minor"]
    ctx = (f"\n  seed={seed} step={step} op={op}\n  state={st}\n  server_rta={rta}"
           f"\n  recent_ops={log[-6:]}")
    assert st["alloc_all"] == 0, "I1 ledger not balanced" + ctx
    assert rta == st["uncategorized_cash"] + st["alloc_none"], "I2 RTA != cash + alloc(None)" + ctx
    assert rta + st["assigned_total"] == st["uncategorized_cash"], "I3 RTA + assigned != cash" + ctx
    assert st["transfer_leg_total"] == 0, "I4 transfer legs do not net to zero" + ctx
    assert st["split_ok"], "I5 split parts != parent amount" + ctx


def build_world(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    checking, groceries = create_budget_structure(client, owner_token, budget["id"])
    savings = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token),
                          json={"name": "Savings", "account_type": "savings"}).json()
    card = create_credit_card(client, owner_token, budget["id"])
    cats = [groceries]
    for name in ("Dining", "Fuel", "Fun"):
        cats.append(add_category(client, owner_token, budget["id"], "Everyday", name))
    return budget["id"], checking, savings, card, cats


def run_sequence(client, owner_token, session_factory, seed, steps=32):
    rng = random.Random(seed)
    b, checking, savings, card, cats = build_world(client, owner_token, session_factory)
    log: list[str] = []

    def cat_rows():
        return {r["category_id"]: r for r in summary(client, owner_token, b)["categories"]}

    def rta():
        return summary(client, owner_token, b)["ready_to_assign_minor"]

    def version():
        return summary(client, owner_token, b)["allocation_version"]

    ops = ["income", "assign", "move", "spend", "refund", "transfer", "split",
           "credit_purchase", "target", "schedule"]

    # Seed with an initial inflow so later ops have money to work with.
    fund(client, owner_token, b, checking["id"], amount=200000)
    log.append("seed-income 200000")
    assert_invariants(client, owner_token, session_factory, b, seed=seed, step=-1, op="seed", log=log)

    for step in range(steps):
        op = rng.choice(ops)
        applied = op
        try:
            if op == "income":
                amt = rng.randint(5000, 80000)
                r = client.post(f"/api/v1/budgets/{b}/transactions", headers=auth(owner_token),
                                json={"account_id": checking["id"], "amount_minor": amt, "occurred_on": MONTH, "payee_name": "Inflow"})
                applied = f"income {amt} -> {r.status_code}"
            elif op == "assign":
                r_now = rta()
                if r_now <= 0:
                    applied = "assign skipped (no RTA)"
                else:
                    cat = rng.choice(cats)
                    rows = cat_rows()
                    current = rows[cat["id"]]["assigned_minor"]
                    delta = rng.randint(1, r_now)
                    r = client.put(f"/api/v1/budgets/{b}/categories/{cat['id']}/assignment", headers=auth(owner_token),
                                   json={"month": MONTH, "assigned_minor": current + delta})
                    applied = f"assign {cat['name']} +{delta} -> {r.status_code}"
            elif op == "move":
                rows = cat_rows()
                funded = [c for c in cats if rows[c["id"]]["available_minor"] > 0]
                if not funded:
                    applied = "move skipped (nothing available)"
                else:
                    src = rng.choice(funded)
                    dst = rng.choice([c for c in cats if c["id"] != src["id"]])
                    amt = rng.randint(1, rows[src["id"]]["available_minor"])
                    r = client.post(f"/api/v1/budgets/{b}/allocation-transfers", headers=auth(owner_token),
                                    json={"source_category_id": src["id"], "destination_category_id": dst["id"],
                                          "amount_minor": amt, "occurred_on": MONTH, "expected_allocation_version": version()})
                    applied = f"move {src['name']}->{dst['name']} {amt} -> {r.status_code}"
            elif op == "spend":
                cat = rng.choice(cats)
                amt = rng.randint(1000, 30000)
                r = client.post(f"/api/v1/budgets/{b}/transactions", headers=auth(owner_token),
                                json={"account_id": checking["id"], "category_id": cat["id"], "amount_minor": -amt, "occurred_on": MONTH, "payee_name": "Store"})
                applied = f"spend {cat['name']} -{amt} -> {r.status_code}"
            elif op == "refund":
                cat = rng.choice(cats)
                amt = rng.randint(500, 10000)
                r = client.post(f"/api/v1/budgets/{b}/transactions", headers=auth(owner_token),
                                json={"account_id": checking["id"], "category_id": cat["id"], "amount_minor": amt, "occurred_on": MONTH, "payee_name": "Refund"})
                applied = f"refund {cat['name']} +{amt} -> {r.status_code}"
            elif op == "transfer":
                bal = independent_cash(session_factory, b, checking["id"])
                if bal <= 1000:
                    applied = "transfer skipped (low balance)"
                else:
                    amt = rng.randint(1000, max(1000, bal // 2))
                    r = client.post(f"/api/v1/budgets/{b}/transfers", headers=auth(owner_token),
                                    json={"source_account_id": checking["id"], "destination_account_id": savings["id"],
                                          "amount_minor": amt, "occurred_on": MONTH})
                    applied = f"transfer checking->savings {amt} -> {r.status_code}"
            elif op == "split":
                a, c = rng.sample(cats, 2)
                p1 = rng.randint(1000, 15000)
                p2 = rng.randint(1000, 15000)
                r = client.post(f"/api/v1/budgets/{b}/transactions", headers=auth(owner_token),
                                json={"account_id": checking["id"], "amount_minor": -(p1 + p2), "occurred_on": MONTH, "payee_name": "Split",
                                      "splits": [{"category_id": a["id"], "amount_minor": -p1}, {"category_id": c["id"], "amount_minor": -p2}]})
                applied = f"split {p1}+{p2} -> {r.status_code}"
            elif op == "credit_purchase":
                cat = rng.choice(cats)
                amt = rng.randint(1000, 20000)
                r = client.post(f"/api/v1/budgets/{b}/transactions", headers=auth(owner_token),
                                json={"account_id": card["id"], "category_id": cat["id"], "amount_minor": -amt, "occurred_on": MONTH, "payee_name": "Card"})
                applied = f"credit_purchase {cat['name']} -{amt} -> {r.status_code}"
            elif op == "target":
                cat = rng.choice(cats)
                amt = rng.randint(10000, 200000)
                r = client.put(f"/api/v1/budgets/{b}/categories/{cat['id']}/target", headers=auth(owner_token),
                               json={"target_type": "monthly_funding", "target_amount_minor": amt})
                applied = f"target {cat['name']} {amt} -> {r.status_code} (money no-op)"
            elif op == "schedule":
                cat = rng.choice(cats)
                amt = rng.randint(1000, 50000)
                r = client.post(f"/api/v1/budgets/{b}/scheduled-transactions", headers=auth(owner_token),
                                json={"account_id": checking["id"], "category_id": cat["id"], "name": "Future",
                                      "amount_minor": -amt, "next_date": "2026-12-01", "recurrence_unit": "months"})
                applied = f"schedule {cat['name']} -{amt} -> {r.status_code} (money no-op)"
        except Exception as exc:  # pragma: no cover - surfaces context on unexpected failure
            raise AssertionError(f"operation raised: seed={seed} step={step} op={op}: {exc}\n  recent={log[-6:]}")
        log.append(applied)
        assert_invariants(client, owner_token, session_factory, b, seed=seed, step=step, op=applied, log=log)


def independent_cash(session_factory, budget_id, account_id):
    with session_factory() as db:
        return int(sum(t.amount_minor for t in db.scalars(
            select(Transaction).where(Transaction.budget_id == budget_id, Transaction.account_id == account_id)
        ).all()))


# A small fixed panel of seeds keeps the run reproducible and fast; each seed is an
# independent 32-step sequence. Bump the range locally to fuzz harder.
def test_money_conservation_over_seeded_operation_sequences(client, owner_token, session_factory):
    for seed in (1, 7, 42, 1337, 2026):
        run_sequence(client, owner_token, session_factory, seed=seed, steps=32)


def test_targets_and_schedules_are_conservation_neutral(client, owner_token, session_factory):
    """Creating targets and (unrealized) schedules must not move any conservation quantity."""
    b, checking, savings, card, cats = build_world(client, owner_token, session_factory)
    fund(client, owner_token, b, checking["id"], amount=150000)
    client.put(f"/api/v1/budgets/{b}/categories/{cats[0]['id']}/assignment", headers=auth(owner_token),
               json={"month": MONTH, "assigned_minor": 40000})
    before = independent_state(session_factory, b)
    before_rta = summary(client, owner_token, b)["ready_to_assign_minor"]
    for cat in cats:
        client.put(f"/api/v1/budgets/{b}/categories/{cat['id']}/target", headers=auth(owner_token),
                   json={"target_type": "monthly_funding", "target_amount_minor": 999999})
        client.post(f"/api/v1/budgets/{b}/scheduled-transactions", headers=auth(owner_token),
                    json={"account_id": checking["id"], "category_id": cat["id"], "name": "F",
                          "amount_minor": -50000, "next_date": "2026-12-01", "recurrence_unit": "months"})
        client.post(f"/api/v1/budgets/{b}/scheduled-transactions", headers=auth(owner_token),
                    json={"account_id": checking["id"], "name": "Inflow", "amount_minor": 500000,
                          "next_date": "2026-12-01", "recurrence_unit": "months"})
    after = independent_state(session_factory, b)
    assert after == before, (before, after)
    assert summary(client, owner_token, b)["ready_to_assign_minor"] == before_rta
