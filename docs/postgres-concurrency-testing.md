# PostgreSQL Concurrency Testing

`server/tests/test_pg_concurrency.py` proves the money-critical locking paths under **genuinely overlapping PostgreSQL transactions** — closing the earlier caveat that SQLite single-threaded tests only proved sequential duplicate rejection.

## How it works
- A real PostgreSQL server is used (the schema is built **via `alembic upgrade head`**, not `create_all`, so migrations are exercised on Postgres).
- Setup runs through the normal HTTP routes (`TestClient` bound to the Postgres session factory).
- The **race phase** starts two worker threads, each with **its own SQLAlchemy `Session`** on the same database, and calls the real route function directly (`realize_scheduled_transaction`, `decide_request`, `transfer_allocation`, `reconcile_account`). A `threading.Barrier` releases both workers together so they enter the `SELECT … FOR UPDATE` / optimistic-version region simultaneously and the row locks actually contend.
- Every worker's outcome is classified `ok` / `conflict(status)`, and the **final persistent state is verified independently** from stored rows (transaction counts, allocation operations/postings, reserve events, schedule `next_date`/`last_realized_on`, request status, adjustment rows) — never from HTTP status alone. All money assertions are exact `Int64` minor units.

## Scenarios
| Test | Proves |
|---|---|
| `test_concurrent_realize_expense_creates_exactly_one_transaction` | Two realizes of one due occurrence → exactly one actual transaction; schedule advances once; loser gets 422 |
| `test_concurrent_realize_transfer_creates_exactly_one_pair` | Concurrent transfer realization → exactly one balanced two-leg pair |
| `test_concurrent_realize_credit_purchase_moves_reserve_once` | Concurrent credit-purchase realization → one reserve movement, no duplicate |
| `test_concurrent_full_approvals_move_money_once` | Two full approvals → one wins (409 other); one `request_approval` op, two postings |
| `test_concurrent_partial_approvals_move_money_once` | Two partial approvals from the same version → money moves once |
| `test_concurrent_delegated_moves_cannot_exceed_authority` | Two in-sandbox moves that together exceed the pool → at most one succeeds; controlled allocation stays == authority; pool never negative |
| `test_concurrent_moves_from_same_version_have_one_winner` | Optimistic version race → one applies, stale writer 409; ledger balanced; no lost update |
| `test_concurrent_reconciliation_creates_one_adjustment` | Two adjusting reconciliations → exactly one adjustment (account lock + expected-cleared guard) |
| `test_locking_does_not_let_an_unauthorized_actor_through` | Under contention, an unauthorized/out-of-scope actor is still denied; authorization is not bypassed by the lock |

## Running it

**Locally**, point at any PostgreSQL 14+ database (its `public` schema is dropped and rebuilt):
```bash
export BUDGET_APP_TEST_PG_URL='postgresql+psycopg://budget:test-database-password@127.0.0.1:5432/budget_test'
cd server && pytest tests/test_pg_concurrency.py -v
```
A throwaway server via Docker:
```bash
docker run --rm -d --name budgetpg -e POSTGRES_DB=budget_test -e POSTGRES_USER=budget \
  -e POSTGRES_PASSWORD=test-database-password -p 5432:5432 postgres:17-alpine
```

**Without a database**, the tests **skip explicitly** (`BUDGET_APP_TEST_PG_URL not set`) — they never silently fall back to SQLite and never claim concurrency was proven.

**CI:** the `server` job in `.github/workflows/verify.yml` already runs a `postgres:17-alpine` service; a dedicated `PostgreSQL concurrency tests` step runs this file against it with `BUDGET_APP_TEST_PG_URL` set, so the race tests execute on every push/PR.

## Notes & limitations
- Isolation: `public` is dropped + re-migrated once per session; each test `TRUNCATE … RESTART IDENTITY CASCADE`s all tables. Assumes a **non-parallel** pytest run (default); do not run this file under `pytest-xdist` against one shared database.
- The tests contend on **row locks** (`with_for_update`) and the **optimistic `allocation_version`/request `version`** guards — the exact production mechanisms. They do not test `SERIALIZABLE` isolation (the app relies on row locks + version checks, not serializable retries).
- PostgreSQL version validated in CI: **17** (`postgres:17-alpine`). Any 14+ server should behave identically for these locks.

## Real recovery regression

`tests/test_pg_recovery.py` uses the same explicitly disposable source fixture and requires
`pg_dump` / `pg_restore` plus permission to create a database on that test cluster. It generates a
unique `budget_recovery_<uuid>` destination, restores there, and drops only that generated
destination afterward. It never restores into an existing destination. Attachment roots are
temporary directories, including for the shared PostgreSQL fixture.

The representative fixture includes income, reconciled spending, assignment postings, a funded
credit purchase/reserve, an account transfer, first-class payees, a schedule, member grant, debt
terms and an encrypted attachment. It compares all model-table rows plus authoritative balance,
month summary, transaction, payee, schedule and debt-term responses. It also checks the migration
head, attachment plaintext digest after restoration, wrong-key rejection and corruption rejection
without altering the source ciphertext.

Run with the same `BUDGET_APP_TEST_PG_URL` safety rules:
```bash
cd server
pytest tests/test_pg_concurrency.py tests/test_pg_recovery.py -v
```
This proves real PostgreSQL and attachment-ciphertext recovery, **not** the outer `age` archive or
Docker Compose orchestration. Those remain distinct end-to-end deployment gates.
