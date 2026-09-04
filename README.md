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
- [iPhone app](ios/README.md)

## Active milestone

Complete remaining iPhone creation and split-transaction workflows, then add encrypted backup/restore, exports, deployment hardening, and end-to-end release verification.
