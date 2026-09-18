# Self-hosting guide

This guide deploys Budget App on one Linux host with Docker Compose and Caddy. The API stays bound to loopback; Caddy is the only public listener and obtains TLS certificates automatically.

## Prerequisites

- A Linux server with Docker Engine and the Compose plugin
- A DNS name pointing to that server
- TCP ports 80 and 443 open to Caddy
- `age` installed for encrypted backups
- Python 3.10+ on the backup host for standard-library archive/integrity preflight; no application
  Python environment or third-party package is needed for that helper

## Configure

From `server/`, create the deployment environment:

```sh
cp .env.example .env
openssl rand -base64 36
openssl rand -base64 48
```

Use the first generated value as `BUDGET_APP_DB_PASSWORD` and the second as `BUDGET_APP_JWT_SECRET`. Set `BUDGET_APP_ALLOWED_HOSTS` to the exact public hostname. Do not commit `.env`; it is ignored by Git.

Copy `server/Caddyfile.example` to your Caddy configuration and replace `budget.example.com`. When Caddy runs on another machine, keep the API behind a private network instead of publishing port 8080 publicly.

## Start and initialize

```sh
docker compose up -d --build
docker compose ps
docker compose logs api
```

Open `https://your-host/admin` and choose **First setup**. Bootstrap is atomically disabled as soon as the first owner and household exist.

## Update

Create an encrypted backup first, pull the desired revision, and rebuild:

```sh
./scripts/backup.sh --project-name budget-server
git pull --ff-only
docker compose up -d --build
```

The API container applies forward-only database migrations before accepting traffic. Pin deployments to a tested Git tag or commit when stability matters.

## Routine operations

- Run `./scripts/backup.sh --project-name budget-server` on a schedule and copy encrypted files off-host.
- Perform a test restore on a separate instance periodically.
- Monitor `docker compose ps` and the `/api/v1/health` endpoint.
- Renew the JWT secret only as a deliberate sign-out-all-users operation.
- Apply host OS, Docker, Caddy, and Budget App updates promptly.

## Recovery destination safety

Restore into a new/schema-only deployment with empty attachment storage and the matching encryption
configuration. Do not bootstrap that destination first. Keep the source deployment and backup intact;
use a separate host or deliberately isolated project/ports/volumes. The restore script refuses existing
application rows or objects, quiesces the recovery API, copies under the normal service identity and
uses a locked empty-database guard plus SQL restore in one transaction. Failures leave the recovery
API stopped; partial recovery is not safe to serve. There is no in-place overwrite bypass.

After successful recovery, check health, financial observations and an attachment download before
any client cutover. Starting a container is not proof that migrations/health succeeded. Docker's
[one-off service command](https://docs.docker.com/reference/cli/docker/compose/run/) preserves service
configuration/volumes without publishing service ports; the recovery helper does not run an extra API.
Do not share those volumes with another writer during recovery.

## Network choices

For home-only access, a private mesh VPN is preferable to exposing the app publicly. If it is internet-facing, retain Caddy's HTTPS and security headers, use unique strong passwords, and never publish PostgreSQL's port.
