# Budget App server

The API is a FastAPI service backed by PostgreSQL in production. Authentication and budget visibility are enforced on the server. SQLite is used only by the automated test suite.

## Environment

- `BUDGET_APP_DATABASE_URL`: SQLAlchemy PostgreSQL URL, such as `postgresql+psycopg://budget:password@localhost/budget`
- `BUDGET_APP_JWT_SECRET`: randomly generated secret of at least 32 characters

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

Household owners can issue seven-day, single-use invitation tokens for adults or children, list members, grant only selected budgets, revoke individual grants, and deactivate members. Invitation secrets are stored only as SHA-256 hashes; revocation and deactivation affect existing sessions immediately because every protected query rechecks active membership and grants.

## Container deployment

Copy `.env.example` to `.env`, replace both example values with independently generated random secrets, and run `docker compose up -d`. The API binds to localhost port 8080 by default so it can sit safely behind a TLS reverse proxy or a private-network VPN.

## Desktop administration

Open `/admin` on the same server. The responsive owner console supports first-time setup, sign-in, invitation acceptance, budget/account/category creation, transaction entry, monthly assignment editing, and family access administration. Its bearer token remains in memory rather than browser storage, and the page uses a restrictive Content Security Policy with no third-party scripts.
