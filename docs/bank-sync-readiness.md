# Bank-sync readiness gate

Status: **BLOCKED UNTIL EXPLICIT FUTURE APPROVAL.**

Budget App v0.4.0 contains no Plaid, MX, Finicity, Akoya, Teller, Apple Card, institution OAuth, scraping, credential storage, or live institution code. Manual entry and the self-hosted server remain authoritative; deterministic demo data is only a review fixture.

## Threat model

Before selecting a provider, document assets (access/refresh tokens, account identifiers, transactions, balances, webhooks), actors, trust boundaries, host compromise, database exfiltration, malicious household members, replay, confused-deputy access, SSRF, provider compromise, and availability loss. Complete data-flow and abuse-case diagrams and obtain an independent review.

## Required controls

- **Secrets:** runtime secret manager or host-mounted secrets; never source control, images, logs, client bundles, backups without protection, or environment dumps.
- **Token encryption:** envelope encryption with independently rotated keys; authenticated encryption; per-record context; no plaintext provider tokens in PostgreSQL.
- **Network isolation:** provider adapter in a narrow service boundary with outbound allowlisting, strict timeouts, retry budgets, and no access to password hashes or authorization administration.
- **Least privilege:** request the smallest provider scopes; read-only transactions/balances unless a separately reviewed product need exists.
- **Webhook validation:** verify signatures over raw bodies, enforce timestamp windows, reject replay, store idempotency keys, and rate-limit before parsing.
- **Logging:** redact tokens, institution identifiers, account numbers, transaction descriptions where unnecessary, webhook bodies, and authorization headers. Security logs need access controls and retention limits.
- **Retention:** define what is stored, why, for how long, and how deletion propagates through database, object storage, logs, and backups.
- **Backups:** document whether encrypted provider tokens are backed up, how keys are separated, recovery authorization, and connection invalidation after restore.
- **Provider isolation:** one adapter contract and provider-specific worker; no provider semantics in the accounting ledger.

## Financial integrity

- Normalize imported data into a staging area, never directly into actual transactions.
- Deduplicate using provider IDs plus a deterministic fallback fingerprint and explicit merge history.
- Require an imported-transaction approval/matching workflow; suggestion is not mutation.
- Preserve manual transaction identity when matching an import.
- Define pending-to-cleared transitions, amount/date changes, deletions, refunds, transfers, and credit-card payments.
- Reconciliation remains authoritative. Imports cannot silently rewrite reconciled history.
- Rollback removes or reverses import effects without deleting audit evidence.
- Provider outages display stale-as-of timestamps, back off safely, and never fabricate zero balances.

## Household authorization

Provider connections belong to a household but each imported account must obey existing account and category resource grants. A user who cannot view an account cannot view its connection state, institution name, balance, raw transactions, diagnostics, or webhook-derived events. Connecting, reconnecting, removing, and exporting provider data require separate capabilities and owner-visible audit events.

## Connection lifecycle

Before implementation, specify consent, link, reauthorization, scope change, token rotation, outage, revoked access, account disappearance, household transfer, user deactivation, and deletion. “Remove connection” must revoke provider access, stop webhooks/jobs, erase tokens, preserve appropriately redacted accounting audit history, and clearly explain retained records.

## Exit criteria

Bank synchronization may begin only after explicit approval of:

1. provider and data-processing terms;
2. completed threat model and security review;
3. token/key architecture;
4. staging, matching, deduplication, and approval specifications;
5. permission and audit design;
6. retention/deletion/backup policy;
7. incident, outage, rollback, and provider-removal runbooks;
8. automated security and accounting-invariant tests.
