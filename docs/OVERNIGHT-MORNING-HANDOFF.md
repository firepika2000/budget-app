# Overnight Engineering — Morning Handoff

This is a durable, incrementally updated handoff for the autonomous run beginning 2026-09-16.
It records engineering evidence separately from human acceptance and does not authorize a merge,
tag, or release.

## Repository checkpoint

- Current branch: `codex/v0.4.0-stabilization`
- Overnight starting HEAD: `f44c38f9a163e32133f3ca4c7108ad488db2f836`
- Current/remote HEAD: `f44c38f9a163e32133f3ca4c7108ad488db2f836` before the first overnight commit
- Push status: first overnight checkpoint verified locally; commit/push pending
- Human Live database at start: `0020_payee_identity_repair`
- Human Simulator: preserved iPhone 17 Pro Max / iOS 27.0; no erase/reset/uninstall

## v0.5 checkpoint — Payee identity hardening

Status: **ENGINEERING VERIFIED — commit/push pending**

Defects reproduced and corrected in the working tree:

- canonical payee names and aliases did not share one deterministic collision namespace;
- a merged source name was discarded, allowing future typed use to create a new identity;
- an archived payee's alias could be recreated as a new active payee;
- scoped members could receive/search household alias metadata for an otherwise visible payee;
- schedules retained only payee text, so rename/merge could disconnect later realization from the
  original canonical identity.

The correction adds collision/privacy enforcement, deterministic merge aliases, 10,000-payee bounded
search characterization, and stable nullable `scheduled_transactions.payee_id` linkage. Payee rename
and merge update linked future schedules; realization resolves the current canonical identity. A new
typed schedule remains text-only until realization unless it matches an existing identity, so merely
canceling or saving forecast metadata does not create a new household payee.

### Migration ledger

| Version | Revision | Previous | Purpose | Data transformation | Automated populated upgrade | Human Live application |
|---|---|---|---|---|---|---|
| v0.5 | `0021_scheduled_payee_id` | `0020_payee_identity_repair` | Add nullable scheduled-payee FK/index and safely link exact normalized active canonical/alias matches | Yes; links only, creates/merges nothing | Focused PASS; full suite pending | REQUIRED/PENDING; do not apply automatically |

### API ledger

- Existing `POST/PUT/GET /api/v1/budgets/{budget_id}/scheduled-transactions` contract gains nullable
  `payee_id`. Authorization and schedule money-neutrality are unchanged.
- Existing payee create/update/alias/merge/search routes now reject deterministic name collisions and
  omit alias metadata/matching for resource-scoped callers.

### Financial ledger

No financial semantics changed. Payee and schedule identity metadata remain money-neutral. Scheduled
realization still routes through the existing authoritative transaction/card engine exactly once.

### Verification

- Focused backend/payee/schedule/attachment/migration: PASS (44 tests).
- Full backend: PASS (189 passed, 9 PostgreSQL-only skipped). The unrestricted run was required only
  for the launcher's intentional loopback-bind test.
- Swift package: PASS (27 BudgetCore + 33 BudgetAPI).
- Native XCTest: PASS (67 tests) on Xcode 27.0 Beta, iPhone 17 Pro Max / iOS 27.0. Xcode executed
  every test successfully, then repeated its existing result-log finalization stall; only the stalled
  finalizer was interrupted.
- `git diff --check`: PASS.

## Human acceptance status

### HUMAN PASSED

- Payee search/filter: Activity → Filter → Payee → search `Meta` → `Metadata test` → Apply returned
  exactly the expected transaction.
- All acceptance evidence listed in `V0.5-CLOSURE-AUDIT.md` before the overnight run remains valid
  unless explicitly listed under invalidation below.

### HUMAN PENDING

- New typed payee creation remains pending; it has not been human-tested.
- Payee rename/alias/archive/merge and one representative schedule realization remain pending.
- Later sections will consolidate remaining browser/bulk/attachment/recovery checks.

### HUMAN ACCEPTANCE INVALIDATED BY LATER CHANGE

None. The overnight identity correction does not alter the already-passed `Metadata test` search/filter
interaction or any accepted financial/clearing/reconciliation behavior.

### DO NOT RETEST

Do not repeat canonical quick clearing, reconciliation invariants, credential rotation, migration 0020
continuity, prior image upload/preview/removal, basic void/reversal, or the accepted `Metadata test`
Payee search/filter unless a later section explicitly records invalidation.

### BLOCKED

None at this checkpoint.

## Morning build and migration plan (current; final HEAD will supersede)

- Xcode: `/Users/firepika/Downloads/Xcode-beta.app`
- Simulator: existing iPhone 17 Pro Max / iOS 27.0
- Clean build required: NO evidence yet
- Normal Cmd-R build sufficient: expected YES
- Simulator reset required: NO
- Rebuild required: YES after final overnight Swift changes
- Server restart required: YES after final pull/migration
- Migration required: YES, currently `0020_payee_identity_repair` → `0021_scheduled_payee_id`
- Backup before Live migration: recommended as routine safety; migration is additive and its data
  transformation only links unambiguous active Payees to existing schedules.

Exact final commands and consolidated acceptance steps will be updated after the final pushed checkpoint.
