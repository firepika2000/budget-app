"""True concurrent PostgreSQL race tests for the money-critical locking paths.

These exercise genuinely overlapping transactions (separate SQLAlchemy sessions on
a real PostgreSQL server, synchronized with a threading.Barrier) against the same
`SELECT ... FOR UPDATE` / optimistic-version mechanisms used in production. They
call the route functions directly so two independent DB transactions contend on
the same rows — unlike the deterministic SQLite tests, this proves the row locks
actually serialize simultaneous callers.

They run only when a PostgreSQL server is provided via BUDGET_APP_TEST_PG_URL and
otherwise **skip explicitly** (they never silently fall back to SQLite). See
docs/postgres-concurrency-testing.md.
"""

from __future__ import annotations

import os
import threading
from datetime import date
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import sessionmaker

from app.config import Settings
from app.database import Base
from app.main import create_app
from app.models import (
    AllocationOperation,
    AllocationPosting,
    Category,
    CreditCardReserveEvent,
    FinancialRequest,
    ScheduledTransaction,
    Transaction,
    User,
)
from app.schemas import AllocationTransferCreate, FinancialRequestDecision, ReconcileRequest
from app.planning_routes import realize_scheduled_transaction
from app.request_routes import decide_request
from app.budgeting_routes import transfer_allocation, reconcile_account

from .conftest import auth
from .test_advanced_ledger import add_category, record
from .test_allocation_ledger import fund
from .test_budgeting_api import create_budget, create_budget_structure
from .test_credit_cards import create_credit_card
from .test_delegated_access import _delegate_with_pool, add_child, configure_child

PG_URL = os.environ.get("BUDGET_APP_TEST_PG_URL")
MONTH = "2026-09-01"
PAST = "2026-09-01"


def _reachable(url: str) -> bool:
    try:
        engine = create_engine(url)
        engine.connect().close()
        engine.dispose()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not PG_URL or not _reachable(PG_URL),
    reason="PostgreSQL not available; set BUDGET_APP_TEST_PG_URL to run true concurrency tests",
)


@pytest.fixture(scope="session")
def pg_migrated():
    """Reset the target database and build its schema **via migrations** (not create_all)."""
    engine = create_engine(PG_URL)
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA IF EXISTS public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    from alembic import command
    from alembic.config import Config

    previous = os.environ.get("BUDGET_APP_DATABASE_URL")
    os.environ["BUDGET_APP_DATABASE_URL"] = PG_URL
    try:
        command.upgrade(Config(str(Path(__file__).parents[1] / "alembic.ini")), "head")
    finally:
        # Do not leak the URL into the sqlite migration tests that share this pytest run.
        if previous is None:
            os.environ.pop("BUDGET_APP_DATABASE_URL", None)
        else:
            os.environ["BUDGET_APP_DATABASE_URL"] = previous
    yield engine
    engine.dispose()


@pytest.fixture
def pg(pg_migrated):
    engine = pg_migrated
    tables = ", ".join(f'"{t.name}"' for t in Base.metadata.sorted_tables)
    with engine.begin() as conn:
        conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    app = create_app(Settings(database_url=PG_URL, jwt_secret="test-secret-that-is-longer-than-32-characters"))
    app.state.session_factory = factory
    with TestClient(app) as client:
        boot = client.post("/api/v1/auth/bootstrap", json={
            "email": "owner@example.com", "password": "correct horse battery staple",
            "display_name": "Owner", "household_name": "Home",
        })
        assert boot.status_code == 201
        token = boot.json()["access_token"]
        with factory() as db:
            owner_id = db.scalar(select(User.id).where(User.email == "owner@example.com"))
        yield SimpleNamespace(engine=engine, factory=factory, client=client, token=token, owner_id=owner_id)


# ---------------------------------------------------------------------------
# Concurrency harness
# ---------------------------------------------------------------------------

def run_race(builders):
    """Run len(builders) callables so they enter their critical section together.

    Each builder is `builder(barrier) -> result`; it opens its own session, waits
    on the shared barrier, then performs the operation. Returns the per-worker
    results in order.
    """
    n = len(builders)
    barrier = threading.Barrier(n, timeout=30)
    results: list = [None] * n
    exceptions: list = [None] * n

    def worker(i):
        try:
            results[i] = builders[i](barrier)
        except BaseException as exc:  # noqa: BLE001 - surfaced below
            exceptions[i] = exc

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=45)
    for i, exc in enumerate(exceptions):
        if exc is not None:
            raise AssertionError(f"worker {i} raised unexpectedly: {exc!r}")
    return results


def route_attempt(factory, user_id, call):
    """Build a worker that runs `call(db, user)` inside its own session and classifies
    the outcome as ("ok", value) or ("conflict", status_code)."""
    def builder(barrier):
        with factory() as db:
            user = db.get(User, user_id)
            barrier.wait()
            try:
                value = call(db, user)
                return ("ok", value)
            except HTTPException as exc:
                db.rollback()
                return ("conflict", exc.status_code)
    return builder


def outcomes(results):
    return sorted(kind for kind, _ in results)


# ---------------------------------------------------------------------------
# 1. Scheduled realization double-realize
# ---------------------------------------------------------------------------

def _schedule(pg, **body):
    r = pg.client.post(f"/api/v1/budgets/{body.pop('budget_id')}/scheduled-transactions",
                       headers=auth(pg.token), json=body)
    assert r.status_code == 201, r.text
    return r.json()["id"]


def test_concurrent_realize_expense_creates_exactly_one_transaction(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, category = create_budget_structure(pg.client, pg.token, budget["id"])
    fund(pg.client, pg.token, budget["id"], account["id"], amount=200000)
    pg.client.put(f"/api/v1/budgets/{budget['id']}/categories/{category['id']}/assignment",
                  headers=auth(pg.token), json={"month": MONTH, "assigned_minor": 50000})
    sid = _schedule(pg, budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
                    name="Rent", amount_minor=-40000, next_date=PAST, recurrence_unit="months")

    def call(db, user):
        return realize_scheduled_transaction(budget_id=budget["id"], schedule_id=sid, user=user, db=db)

    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results) == ["conflict", "ok"], results
    conflict = next(s for k, s in results if k == "conflict")
    assert conflict == 422  # advanced past due

    with pg.factory() as db:
        txns = db.scalars(select(Transaction).where(Transaction.scheduled_transaction_id == sid)).all()
        assert len(txns) == 1
        assert txns[0].amount_minor == -40000
        schedule = db.get(ScheduledTransaction, sid)
        assert schedule.last_realized_on is not None
        assert schedule.next_date > date(2026, 9, 1)  # advanced exactly once


def test_concurrent_realize_transfer_creates_exactly_one_pair(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    checking, _ = create_budget_structure(pg.client, pg.token, budget["id"])
    savings = pg.client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(pg.token),
                             json={"name": "Savings", "account_type": "savings"}).json()
    fund(pg.client, pg.token, budget["id"], checking["id"], amount=100000)
    sid = _schedule(pg, budget_id=budget["id"], account_id=checking["id"], destination_account_id=savings["id"],
                    name="Move", amount_minor=25000, next_date=PAST, recurrence_unit="months")

    def call(db, user):
        return realize_scheduled_transaction(budget_id=budget["id"], schedule_id=sid, user=user, db=db)

    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results) == ["conflict", "ok"], results
    with pg.factory() as db:
        legs = db.scalars(select(Transaction).where(Transaction.scheduled_transaction_id == sid)).all()
        assert len(legs) == 2  # exactly one transfer pair
        assert sum(t.amount_minor for t in legs) == 0
        assert len({t.transfer_id for t in legs}) == 1


def test_concurrent_realize_credit_purchase_moves_reserve_once(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    checking, groceries = create_budget_structure(pg.client, pg.token, budget["id"])
    card = create_credit_card(pg.client, pg.token, budget["id"])
    fund(pg.client, pg.token, budget["id"], checking["id"], amount=100000)
    pg.client.put(f"/api/v1/budgets/{budget['id']}/categories/{groceries['id']}/assignment",
                  headers=auth(pg.token), json={"month": MONTH, "assigned_minor": 50000})
    sid = _schedule(pg, budget_id=budget["id"], account_id=card["id"], category_id=groceries["id"],
                    name="Groceries", amount_minor=-30000, next_date=PAST, recurrence_unit="months")

    def call(db, user):
        return realize_scheduled_transaction(budget_id=budget["id"], schedule_id=sid, user=user, db=db)

    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results) == ["conflict", "ok"], results
    with pg.factory() as db:
        txns = db.scalars(select(Transaction).where(Transaction.scheduled_transaction_id == sid)).all()
        assert len(txns) == 1
        reserves = db.scalars(select(CreditCardReserveEvent).where(
            CreditCardReserveEvent.source_transaction_id == txns[0].id)).all()
        assert sum(r.amount_minor for r in reserves) == 30000  # one funded reserve movement


# ---------------------------------------------------------------------------
# 2. Request double approval
# ---------------------------------------------------------------------------

def _request_setup(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    checking, _ = create_budget_structure(pg.client, pg.token, budget["id"])
    source = add_category(pg.client, pg.token, budget["id"], "Family", "Pool")
    dest = add_category(pg.client, pg.token, budget["id"], "Delegated", "Child Fun")
    record(pg.client, pg.token, budget["id"], account_id=checking["id"], amount_minor=20000, is_cleared=True)
    pg.client.put(f"/api/v1/budgets/{budget['id']}/categories/{source['id']}/assignment",
                  headers=auth(pg.token), json={"month": MONTH, "assigned_minor": 20000})
    child_id, child_token = add_child(pg.factory, pg.client)
    configure_child(pg.client, pg.token, budget["id"], child_id, checking["id"], dest["id"])
    req = pg.client.post(f"/api/v1/budgets/{budget['id']}/requests", headers=auth(child_token),
                         json={"destination_category_id": dest["id"], "requested_amount_minor": 5000, "reason": "x"}).json()
    return budget, source, dest, req


def _approve_call(budget_id, request_id, source_id, amount):
    def call(db, user):
        body = FinancialRequestDecision(decision="approve", expected_request_version=0,
                                        approved_amount_minor=amount, source_category_id=source_id)
        return decide_request(budget_id=budget_id, request_id=request_id, body=body, user=user, db=db)
    return call


def _assert_single_approval(pg, budget, request_id):
    with pg.factory() as db:
        approvals = db.scalars(select(AllocationOperation).where(
            AllocationOperation.budget_id == budget["id"], AllocationOperation.kind == "request_approval")).all()
        assert len(approvals) == 1
        stored = db.get(FinancialRequest, request_id)
        assert stored.status in ("approved", "partially_approved")
        posting_count = db.scalar(select(func.count()).select_from(AllocationPosting).where(
            AllocationPosting.operation_id == approvals[0].id))
        assert posting_count == 2


def test_concurrent_full_approvals_move_money_once(pg):
    budget, source, dest, req = _request_setup(pg)
    call = _approve_call(budget["id"], req["id"], source["id"], 5000)
    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results) == ["conflict", "ok"], results
    assert next(s for k, s in results if k == "conflict") == 409
    _assert_single_approval(pg, budget, req["id"])


def test_concurrent_partial_approvals_move_money_once(pg):
    budget, source, dest, req = _request_setup(pg)
    a = _approve_call(budget["id"], req["id"], source["id"], 3000)
    b = _approve_call(budget["id"], req["id"], source["id"], 2000)
    results = run_race([route_attempt(pg.factory, pg.owner_id, a), route_attempt(pg.factory, pg.owner_id, b)])
    assert outcomes(results) == ["conflict", "ok"], results
    _assert_single_approval(pg, budget, req["id"])


# ---------------------------------------------------------------------------
# 3. Delegated-authority boundary race
# ---------------------------------------------------------------------------

def test_concurrent_delegated_moves_cannot_exceed_authority(pg):
    budget, checking, pool, games, child_id, child_token = _delegate_with_pool(
        pg.client, pg.token, pg.factory,
        capabilities=["view_budget", "view_accounts", "view_categories", "view_transactions", "move_money"],
    )
    authority = 20000  # pool funded to exactly this

    def call(db, user):
        body = AllocationTransferCreate(source_category_id=pool["id"], destination_category_id=games["id"],
                                        amount_minor=15000, occurred_on=PAST)
        return transfer_allocation(budget_id=budget["id"], body=body, user=user, db=db)

    results = run_race([route_attempt(pg.factory, child_id, call) for _ in range(2)])
    # 15000 + 15000 = 30000 > 20000: at most one can succeed.
    assert outcomes(results).count("ok") == 1, results
    assert next(s for k, s in results if k == "conflict") == 409
    with pg.factory() as db:
        controlled = set(db.scalars(select(Category.id).where(
            Category.budget_id == budget["id"], Category.delegated_user_id == child_id)))
        total = sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(
            AllocationPosting.budget_id == budget["id"], AllocationPosting.category_id.in_(controlled))))
        pool_balance = sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(
            AllocationPosting.budget_id == budget["id"], AllocationPosting.category_id == pool["id"])))
        assert total == authority            # authority conserved, never expanded
        assert pool_balance >= 0             # source pool never negative


# ---------------------------------------------------------------------------
# 4. Allocation move / optimistic version race
# ---------------------------------------------------------------------------

def test_concurrent_moves_from_same_version_have_one_winner(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, a = create_budget_structure(pg.client, pg.token, budget["id"])
    b = add_category(pg.client, pg.token, budget["id"], "Everyday", "B")
    fund(pg.client, pg.token, budget["id"], account["id"], amount=100000)
    pg.client.put(f"/api/v1/budgets/{budget['id']}/categories/{a['id']}/assignment",
                  headers=auth(pg.token), json={"month": MONTH, "assigned_minor": 40000})
    version = pg.client.get(f"/api/v1/budgets/{budget['id']}/months/{MONTH}", headers=auth(pg.token)).json()["allocation_version"]

    def call(db, user):
        body = AllocationTransferCreate(source_category_id=a["id"], destination_category_id=b["id"],
                                        amount_minor=5000, occurred_on=PAST, expected_allocation_version=version)
        return transfer_allocation(budget_id=budget["id"], body=body, user=user, db=db)

    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results) == ["conflict", "ok"], results
    assert next(s for k, s in results if k == "conflict") == 409  # stale version rejected
    with pg.factory() as db:
        assert sum(p.amount_minor for p in db.scalars(select(AllocationPosting).where(
            AllocationPosting.budget_id == budget["id"]))) == 0  # ledger still balanced
        moves = db.scalars(select(AllocationOperation).where(
            AllocationOperation.budget_id == budget["id"], AllocationOperation.kind == "category_transfer")).all()
        assert len(moves) == 1  # exactly one move applied (no lost update)


# ---------------------------------------------------------------------------
# 5. Reconciliation adjustment race
# ---------------------------------------------------------------------------

def test_concurrent_reconciliation_creates_one_adjustment(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, _ = create_budget_structure(pg.client, pg.token, budget["id"])
    record(pg.client, pg.token, budget["id"], account_id=account["id"], amount_minor=50000, is_cleared=True)
    cleared = 50000

    def call(db, user):
        body = ReconcileRequest(statement_balance_minor=60000, through_date=date(2026, 9, 5),
                                create_adjustment=True, adjustment_reason="sync",
                                expected_cleared_balance_minor=cleared)
        return reconcile_account(budget_id=budget["id"], account_id=account["id"], body=body, user=user, db=db)

    results = run_race([route_attempt(pg.factory, pg.owner_id, call) for _ in range(2)])
    assert outcomes(results).count("ok") == 1, results
    with pg.factory() as db:
        adjustments = db.scalars(select(Transaction).where(
            Transaction.account_id == account["id"], Transaction.payee_name == "Reconciliation adjustment")).all()
        assert len(adjustments) == 1  # exactly one adjustment created
        assert adjustments[0].amount_minor == 10000


# ---------------------------------------------------------------------------
# 6. Authorization is not bypassed under contention
# ---------------------------------------------------------------------------

def test_locking_does_not_let_an_unauthorized_actor_through(pg):
    budget = create_budget(pg.client, pg.token, pg.factory)
    account, category = create_budget_structure(pg.client, pg.token, budget["id"])
    hidden = add_category(pg.client, pg.token, budget["id"], "Private", "Parent Only")
    fund(pg.client, pg.token, budget["id"], account["id"], amount=100000)
    sid = _schedule(pg, budget_id=budget["id"], account_id=account["id"], category_id=category["id"],
                    name="Rent", amount_minor=-1000, next_date=PAST, recurrence_unit="months")
    # A member scoped only to the hidden category (no access to the schedule's account/category).
    member_id, member_token = add_child(pg.factory, pg.client)
    configure_child(pg.client, pg.token, budget["id"], member_id, account["id"], hidden["id"])

    def call(db, user):
        return realize_scheduled_transaction(budget_id=budget["id"], schedule_id=sid, user=user, db=db)

    results = run_race([
        route_attempt(pg.factory, pg.owner_id, call),      # authorized owner
        route_attempt(pg.factory, member_id, call),        # unauthorized member
    ])
    kinds = {i: results[i][0] for i in range(2)}
    assert kinds[0] == "ok"
    assert kinds[1] == "conflict"  # 403/404 — never slips through under the lock
    with pg.factory() as db:
        assert len(db.scalars(select(Transaction).where(Transaction.scheduled_transaction_id == sid)).all()) == 1
