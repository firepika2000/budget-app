# Changelog

## Unreleased

- Added a balanced, append-only allocation ledger with actor attribution.
- Added first-class category-to-category transfers and client workflows.
- Added optimistic allocation versions and database row locking.
- Enforced real-money-only assignment and explicit actual-versus-future transaction boundaries.
- Added data-preserving assignment backfill and multi-month invariant tests.
- Added category targets with transparent recommended and underfunded amounts.
- Added isolated scheduled transactions and one-year account cash-flow forecasts.
- Scheduled account transfers change projected location without changing projected total cash.
- Added linked system payment categories and an auditable funded-spending reserve for credit cards.
- Credit purchases reserve only funded category money; refunds release it and card payments move cash without creating a second expense.
- Added derived cleared, uncleared, and working account balances.
- Reconciliation differences remain errors by default and can only become explicit, actor-attributed adjustment transactions when requested.
- Added capability-based budget access profiles with independently restricted account and category scopes.
- Added delegated category ownership without duplicating household cash or ledgers.
- Added first-class funding requests, partial approvals, rejection/cancellation states, optimistic request versions, and immutable action history.
- Approved requests now link to a balanced allocation operation funded by an explicit source category.
- Added recurring allowance plans with calendar-safe weekly/monthly schedules and split destinations.
- Added explicit allowance issuance with rollover and use-it-or-lose-it policies; every run links to one balanced allocation operation.
- Added a capability-protected, versioned JSON audit export containing the records needed to reconstruct budget and authorization history.

## 0.1.0 - 2026-09-04

First self-hosted MVP:

- Zero-based monthly budgets using exact minor-unit arithmetic
- Native SwiftUI iPhone client and responsive desktop administration console
- Owner, adult, and child household roles with deny-by-default per-budget grants
- Accounts, categories, assignments, transactions, splits, transfers, and reconciliation
- Single-use family invitations and immediate access revocation
- Argon2 passwords, short-lived access tokens, rotating refresh sessions, and login throttling
- Formula-safe CSV exports and encrypted PostgreSQL backup/restore scripts
- Hardened Docker Compose deployment, Caddy TLS example, migrations, and CI verification
