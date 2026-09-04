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

Household owners can issue seven-day, single-use invitation tokens for adults or children, list members, grant only selected budgets, revoke individual grants, and deactivate members. Invitation secrets are stored only as SHA-256 hashes; revocation and deactivation affect existing sessions immediately because every protected query rechecks active membership and grants.

Authentication uses 30-minute access tokens and rotating 30-day refresh tokens. Refresh secrets are stored only as SHA-256 hashes. Every refresh revokes the prior token; attempting to reuse an already rotated token revokes all remaining refresh sessions for that account. The iPhone stores both secrets in Keychain, while the desktop console keeps them only in memory.

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
