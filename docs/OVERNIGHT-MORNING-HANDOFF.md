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

## v0.5 checkpoint — Activity browser scale and lifecycle filtering

Status: **ENGINEERING VERIFIED — commit/push pending**

The production transaction browser previously called `_visible_transactions`, hydrating every visible
transaction and every split before applying filters, sorting, and pagination in Python. That made the
API response look paginated while its memory/query work remained proportional to the household's full
history.

The browser now applies authorization, resource, text, amount, date, type, clearing, linkage, flag,
tag, member, and lifecycle predicates in SQL; obtains an authorized count independently; uses stable
keyset cursors for every supported sort; and hydrates only `limit + 1` rows plus their splits. The
production Activity filter now distinguishes clearing state from lifecycle and can explicitly select
Posted, Voided, or Reversal rows. Demo uses the same query semantics.

Verification:

- focused Activity/browser/bulk/payee backend: PASS (20 tests before the final lifecycle additions;
  Activity browser suite PASS with 8 tests afterward);
- 3,000-row scale fixture: PASS, with no more than the requested 25 rows plus one look-ahead row loaded;
- insertion between keyset pages: PASS without a duplicate or skipped older row;
- full backend: PASS (193 passed, 9 PostgreSQL-only skipped);
- Swift package: PASS (27 BudgetCore + 33 BudgetAPI);
- native XCTest before the final parity assertion: PASS (67 tests); focused Demo/Live lifecycle parity:
  PASS (1 test) and Xcode build PASS;
- no migration and no financial-semantic change; `git diff --check`: pending final checkpoint.

Human acceptance remains pending for the consolidated Activity search/filter/sort/load-more journey.
No previously accepted workflow is invalidated.

## v0.5 checkpoint — Restricted-resource mutation parity

Status: **ENGINEERING VERIFIED — commit/push pending**

The security audit found that list/search correctly hid uncategorized transactions from a
category-restricted member, but several ID-addressed endpoints treated an empty category set as
permitted. A member who knew the opaque transaction ID could therefore attempt bulk mutation, edit,
delete, duplicate, void, Make Recurring, or attachment access against a row absent from their visible
dataset. Scheduled-transaction list/mutation paths had the equivalent inconsistency.

A canonical transaction-resource guard now applies the same account/category visibility rule to all
of those surfaces and returns a non-disclosing 404. Schedule list, create, edit, delete, and realization
now apply the equivalent live resource scope. Bulk mutation locks selected transaction rows so
concurrent metadata additions serialize instead of losing an update.

Verification:

- focused delegated/bulk/scheduled/void/attachment authorization: PASS (45 tests);
- full backend: PASS (195 passed, 10 PostgreSQL-only skipped);
- a PostgreSQL-only race test now proves concurrent bulk tag additions retain both updates when the
  disposable PostgreSQL concurrency environment is supplied;
- no Swift, migration, or financial-semantic change; native evidence from `bdc7d5e` remains applicable;
- `git diff --check`: pending final checkpoint.

No human-accepted workflow is invalidated. Restricted-member privacy remains HUMAN PENDING as one
consolidated production UI journey.

## v0.5 checkpoint — Backup/restore target and archive validation

Status: **SCRIPT-LEVEL ENGINEERING VERIFIED — real-container drill blocked on host tooling**

The destructive restore script previously relied on Docker Compose's implicit project selection. It
now requires `--project-name NAME`, making the target explicit. Backups include versioned metadata with
the source Alembic revision. Restore verifies required components, all SHA-256 manifest entries, and
the supported archive format before issuing its first Docker mutation. Corrupt, incomplete, future-
format, and missing-target inputs are rejected before the target is touched.

Verification:

- shell syntax: PASS;
- script integration with disposable fake `docker`/`age`: PASS (4 tests), including archive contents,
  explicit source/target selection, integrity failure, completeness failure, and incompatible format;
- real Docker/`age` encrypted restore: BLOCKED because neither executable is installed on this Mac;
- the human Live database, attachment store, and Simulator were not addressed.

This improves operator safety but does not claim the v0.9 consumer backup UI, automatic retention, or
a real-container human restore pass.

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
