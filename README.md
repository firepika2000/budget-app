# Budget App

A self-hostable, zero-based budgeting system with a native iPhone client and privacy-aware family sub-budgets.

## Current status

The repository contains the household-ready financial foundation and native v0.4 product experience:

- Strongly typed household and budget identities with deny-by-default authorization.
- Exact minor-unit money arithmetic and zero-based monthly budget calculations.
- A FastAPI/PostgreSQL server with authentication, scoped budget APIs, append-only allocations, targets, actual and scheduled transactions, transfers, reconciliation, credit reserves, requests, allowances, migrations, and a container deployment definition.
- A native SwiftUI iPhone client with Home, Plan, Activity, Accounts, and Insights; server setup, bootstrap/login, Keychain tokens, budgeting workflows, reports, debt tools, privacy controls, and household-aware presentation.
- One shared five-tab SwiftUI product used by both authenticated self-hosted sessions and a deterministic Debug data source with owner, partner, teen, and child personas.
- Explainable Insights with inclusive 30/60/90-day, 3/6-month, YTD, one-year, and custom ranges; server-side filters; contributing transaction drill-through; and refresh after edits.
- First-class delegated monetary authority, scoped member-created categories, bounded reallocations, and auditable approval requests enforced by the server.
- Production transaction create/edit/delete, exact splits, transfers, reconciliation concurrency checks, flags, tags, attachment metadata, and immutable change history.
- Owner-managed household invitations, explicit sharing, grant revocation, and immediate member deactivation.
- A responsive desktop administration console served directly by the self-hosted backend, with no separate cloud dependency.
- Separate actual and planning ledgers, targets, forecasts, funded credit-card reserves, and explicit reconciliation adjustments.
- Capability-scoped family access, delegated categories, auditable requests/approvals, and recurring allowance policies.
- Formula-safe CSV plus a versioned JSON audit export for owner-controlled portability.

Product and architecture decisions are recorded in `docs/`.

## Run the tests

```sh
swift test
```

## Read next

- [Product brief](docs/product-brief.md)
- [Architecture direction](docs/architecture.md)
- [Architecture review and financial-engine evolution](docs/architecture-review.md)
- [Self-hosting guide](docs/deployment.md)
- [Foundation release checklist](docs/release-checklist.md)
- [v0.4 simulator demo](docs/simulator-demo.md)
- [Delegated-budget architecture](docs/delegated-budget-architecture.md)
- [Insights architecture](docs/insights-architecture.md)
- [v0.4 review](docs/v0.4.0-review.md)
- [Feature-capability review](docs/feature-parity.md)
- [Bank-sync readiness gate](docs/bank-sync-readiness.md)
- [Security policy](SECURITY.md)
- [iPhone app](ios/README.md)

## Active milestone

Version 0.4.0 converges demo and authenticated operation on one native product, hardens delegated monetary authority and reconciliation, and makes Insights explainable. Bank synchronization remains intentionally deferred and blocked pending explicit human approval and security review.
