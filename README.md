# Budget App

A self-hostable, zero-based budgeting system with a native iPhone client and privacy-aware family sub-budgets.

## Current status

The repository contains the first two domain slices:

- Strongly typed household and budget identities with deny-by-default authorization.
- Exact minor-unit money arithmetic and zero-based monthly budget calculations.
- A FastAPI/PostgreSQL server with authentication, private budget APIs, accounts, categories, monthly assignments, split transactions, transfers, reconciliation, monthly summaries, migrations, and a container deployment definition.
- A native SwiftUI iPhone client with server setup, bootstrap/login, Keychain token storage, private budget discovery, monthly planning, transaction entry, and assignment editing.
- Owner-managed household invitations, explicit sharing, grant revocation, and immediate member deactivation.
- A responsive desktop administration console served directly by the self-hosted backend, with no separate cloud dependency.

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
- [MVP release checklist](docs/release-checklist.md)
- [Security policy](SECURITY.md)
- [iPhone app](ios/README.md)

## Active milestone

Version 0.1.0 is the original self-hosted MVP. The active architecture pass now includes an auditable balanced allocation ledger, targets, isolated planning forecasts, funded credit-card payment reserves, capability-scoped delegation, requests and approvals, recurring allowances, and a portable audit export.
