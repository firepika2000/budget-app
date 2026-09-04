# Budget App server

The API is a FastAPI service backed by PostgreSQL in production. Authentication and budget visibility are enforced on the server. SQLite is used only by the automated test suite.

## Environment

- `BUDGET_APP_DATABASE_URL`: SQLAlchemy PostgreSQL URL, such as `postgresql+psycopg://budget:password@localhost/budget`
- `BUDGET_APP_JWT_SECRET`: randomly generated secret of at least 32 characters
- `BUDGET_APP_ALLOWED_HOSTS`: comma-separated hostnames accepted by the API

## Development

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -e '.[dev]'
pytest
export BUDGET_APP_DATABASE_URL='postgresql+psycopg://budget:password@localhost/budget'
export BUDGET_APP_JWT_SECRET='replace-with-a-long-random-value'
alembic upgrade head
uvicorn --factory app.main:create_app --reload
```

The first owner calls `POST /api/v1/auth/bootstrap`. That endpoint becomes permanently unavailable after successful setup.

The versioned API supports budgets, explicit grants, accounts, category groups, categories, monthly assignments, split transactions, balanced account transfers, reconciliation, and monthly zero-based summaries. View, Contribute, and Manage permissions are checked independently for every budget-scoped route.

Assignments and category-to-category moves are persisted as immutable balanced allocation operations. Every operation records its actor and reason, and its postings sum to zero between Ready to Assign and categories. The API uses a budget allocation version plus row locking to reject stale concurrent plan edits. Existing `monthly_assignments` are preserved and backfilled by migration `0006`; new calculations use the allocation ledger.

Category targets support monthly funding, savings balances, target-by-date goals, and recurring expenses. Target recommendations are derived in monthly summaries without changing allocations. Scheduled transactions and transfers are planning-only records; `/forecast` projects account balances for up to one year, while actual balances, activity, and Ready to Assign continue to use only posted transactions and allocation operations.

Every credit account owns a linked system payment category. A categorized card purchase increases the liability and moves only the funded portion of that category's money into the payment reserve. A refund reverses that reserve, and a checking-to-card payment reduces both cash and liability while consuming reserved payment money; it is not reported as another expense. Pre-existing debt and unfunded overspending never fabricate cash or payment reserves and must be covered by an explicit allocation before payment. Reserve changes are immutable events linked to their source transaction or transfer.

`GET /accounts/{account_id}/balance` reports cleared, uncleared, and working balances derived from actual transactions. Reconciliation refuses mismatches by default. When the caller explicitly opts into an adjustment, the difference is stored as a cleared, reconciled, actor-attributed transaction rather than silently changing an account total.

Legacy `view`, `contribute`, and `manage` grants remain supported as capability bundles. An owner can replace a member's bundle with an explicit access profile containing named server-side capabilities and independent account/category allowlists. Once a scope is restricted, omitted resources are deny-by-default across lists, transactions, exports, summaries, targets, schedules, forecasts, reconciliation, and allocation history. Account listing and account-balance visibility are separate capabilities so a delegated user may select an allowed spending account without seeing its household balance.

Funding requests are first-class records with optimistic versions and append-only action history. A requester can target only a visible category. An approver must name the source category; full or partial approval atomically creates one balanced allocation operation and links it back to the request. A stale or repeated approval receives a conflict and cannot move the same allocation twice.

Household owners can issue seven-day, single-use invitation tokens for adults or children, list members, grant only selected budgets, revoke individual grants, and deactivate members. Invitation secrets are stored only as SHA-256 hashes; revocation and deactivation affect existing sessions immediately because every protected query rechecks active membership and grants.

Authentication uses 30-minute access tokens and rotating 30-day refresh tokens. Refresh secrets are stored only as SHA-256 hashes. Every refresh revokes the prior token; attempting to reuse an already rotated token revokes all remaining refresh sessions for that account. The iPhone stores both secrets in Keychain, while the desktop console keeps them only in memory.

Repeated failed password logins are throttled per client and account identifier. This process-local control is defense in depth for the supported single-API-container deployment; an internet-facing reverse proxy should also enforce a broader request-rate limit.

## Container deployment

Copy `.env.example` to `.env`, replace both example values with independently generated random secrets, set the public hostname, and run `docker compose up -d`. The API binds to localhost port 8080 by default so it can sit safely behind a TLS reverse proxy or a private-network VPN. See the repository's self-hosting guide and `Caddyfile.example` for a production path.

## Desktop administration

Open `/admin` on the same server. The responsive owner console supports first-time setup, sign-in, invitation acceptance, budget/account/category creation, transaction entry, monthly assignment editing, and family access administration. Its bearer token remains in memory rather than browser storage, and the page uses a restrictive Content Security Policy with no third-party scripts.

## Exports and encrypted backups

Anyone with view permission can download a budget's ledger from `GET /api/v1/budgets/{budget_id}/export.csv`. The export includes exact minor-unit amounts, currency, split rows, clearing state, and stable IDs. User-entered text is escaped to prevent spreadsheet formula injection.

For a full disaster-recovery backup, install [age](https://age-encryption.org) on the Docker host and run:

```sh
./scripts/backup.sh
```

The script streams `pg_dump` through gzip and passphrase encryption without writing an unencrypted intermediate file. Backups default to `server/backups/`, which is ignored by Git. Store copies away from the server and keep the passphrase separately.

Restore is intentionally explicit because it replaces current database contents:

```sh
./scripts/restore.sh --yes /path/to/budget-YYYYMMDDTHHMMSSZ.sql.gz.age
```

Test recovery periodically on a non-production instance. Database backups do not contain the JWT secret; preserve the deployment `.env` separately in a secure password manager.
