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
