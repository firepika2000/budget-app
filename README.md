# Budget App

A self-hostable, zero-based budgeting system with a native iPhone client and privacy-aware family sub-budgets.

## Current status

The repository contains the household-ready financial foundation:

- Strongly typed household and budget identities with deny-by-default authorization.
- Exact minor-unit money arithmetic and zero-based monthly budget calculations.
- A FastAPI/PostgreSQL server with authentication, scoped budget APIs, append-only allocations, targets, actual and scheduled transactions, transfers, reconciliation, credit reserves, requests, allowances, migrations, and a container deployment definition.
- A native SwiftUI iPhone client with server setup, bootstrap/login, Keychain token storage, private budget discovery, monthly planning, transaction entry, and assignment editing.
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
- [Security policy](SECURITY.md)
- [iPhone app](ios/README.md)

## Active milestone

Version 0.2.0 is the self-hosted household financial foundation: an auditable balanced allocation ledger, targets, isolated planning forecasts, funded credit-card payment reserves, capability-scoped delegation, requests and approvals, recurring allowances, and a portable audit export.
