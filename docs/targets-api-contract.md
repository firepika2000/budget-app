# Category Targets — Locked Server API Contract

Contract the production Targets UI depends on. Verified by `server/tests/test_targets_contract.py` (+ `test_planning.py`) at branch `codex/v0.4.0-stabilization`. **Targets are planning metadata, not money** — no target operation ever creates, moves, or destroys money.

## Principle
Money is exact `Int64` minor units. `account` = where money is; `category` = its purpose. A target only *recommends* an assignment; it never assigns. Future/large targets never increase current spendable (Ready-to-Assign).

## Data model (`category_targets`)
One target per category (`UNIQUE(category_id)`).

| Field | Type | Rules |
|---|---|---|
| `id` | uuid | server-assigned |
| `budget_id`, `category_id` | uuid | category must belong to the budget and be non-archived to create/edit |
| `target_type` | enum | `monthly_funding` \| `savings_balance` \| `target_by_date` \| `recurring_expense` |
| `target_amount_minor` | int64 | `> 0`, `<= 2^63-1` |
| `target_date` | date? | **required** for `target_by_date` and `recurring_expense`; ignored otherwise |
| `recurrence_months` | int? | `1..1200`; **required** for `recurring_expense` (annual = `12`) |
| `minimum_contribution_minor` | int64 | `>= 0` |
| `priority` | int | `0..100` (default 50) |
| `is_active` | bool | default `true`; `false` = snoozed/disabled (produces no recommendation) |
| `created_by_user_id`, `created_at`, `updated_at` | — | audit fields |

## Endpoints (prefix `/api/v1/budgets/{budget_id}`)

### `PUT /categories/{category_id}/target` — create or edit (upsert)
- **Capability:** `manage_planning`. **Scope:** category must be accessible (`can_access_resource`).
- **Body:** `CategoryTargetUpsert` (fields above). Full-object upsert; one row per category.
- **Returns:** `200` `CategoryTargetResponse`.
- **Errors:** `403` (no `manage_planning`), `404` (category missing / archived / out of scope / another budget), `422` (validation).
- **Concurrency:** intentionally **last-writer-wins** — targets are non-monetary metadata, so a second upsert deterministically overwrites (no money can be lost). If the UI later needs conflict detection, add `expected_updated_at`; not required for correctness today. *(caveat)*

### `GET /categories/{category_id}/target` — read
- **Capability:** `view_categories`. **Scope:** enforced.
- **Returns:** `200` `CategoryTargetResponse`, or `200 null` when the visible category has no target. Missing, cross-budget, or out-of-scope categories remain `404` to prevent existence leaks.

### `DELETE /categories/{category_id}/target` — delete  *(added this workstream)*
- **Capability:** `manage_planning`. **Scope:** enforced.
- **Returns:** `204`. `404` when no target / out of scope.
- **Guarantee:** deletes only the target row; **no allocations or transactions are removed and no balances change.**

### `GET /categories/{category_id}/target/history` — immutable decision history
- **Capability:** `view_categories`. **Scope:** enforced with the same non-leaking category-resource check as target read.
- **Query:** bounded `limit=1...100` and nonnegative `offset`; newest decisions first.
- **Returns:** actor-attributed `created`, `updated`, `deleted`, `snoozed`, and `resumed` revisions with exact before/after target snapshots and the affected month when applicable.
- **Guarantees:** identical writes do not create duplicate revisions; deleting a target preserves its history; history is included in complete export and Local Device transfer. Existing hosted targets receive one conservative creation observation during migration from their stored creator and creation timestamp.

## Recommendation / underfunded math (from `planning.target_funding`, surfaced in `GET /months/{month}`)
Per category, the month summary carries `recommended_contribution_minor` and `underfunded_minor`:
- `monthly_funding`: recommend `max(amount, minimum)`.
- `savings_balance`: recommend `max(amount − already-available, minimum)` (progress derives from authoritative allocation/activity, not a stored balance).
- `target_by_date` / `recurring_expense`: recommend the remaining gap spread over the inclusive months to `target_date`, ceiling-divided, floored at `minimum`.
- `underfunded = max(recommendation − assigned, 0)`. `is_active = false` ⇒ `(0, 0)`.
- Rollover: existing category Available reduces the recommendation (proven in `test_planning`).

## Supported vs deferred target behaviors
- **Supported:** monthly funding, savings-balance (up-to), by-date sinking fund, recurring (monthly multiples incl. **annual = 12**), needed-this-period, funded/underfunded, progress via summary, rollover interaction, future-month recommendation without creating cash, enable/disable via `is_active`, month-scoped snooze/resume, aggregate plan cost, and immutable actor-attributed decision history.
- **Deferred (documented, not blocking):** **weekly cadence** (model is month-granular; weekly not representable), spending-style "refill/spent" nuance beyond monthly_funding, and optimistic conflict rejection. Last-writer-wins remains intentional for non-monetary target metadata; history preserves what changed and who changed it.

## Verified test coverage
- Server contract: `test_targets_contract.py` plus populated migration and migration-graph coverage.
- Typed client and Local Device: `APIClientTests` and `LocalDatabaseTests` preserve exact `Int64` snapshots, paging, durable reopen, transfer/export, and stable ordering.
- Native production store: Demo/Local/Live use the same Target History destination; the native regression exercises create → edit → snooze → resume → delete and proves money remains unchanged.

Server coverage includes:
- **Types & round-trip:** all four types create + read back; annual via `recurrence_months=12`.
- **Math:** monthly & savings recommendation/underfunded (by-date in `test_planning`).
- **Accounting invariants:** create/edit/deactivate/delete leave RTA, `allocation_version`, assigned, Σ allocation postings, account balance, and transaction count unchanged; large future target adds no spendable cash; recommendation ≠ assignment; delete removes no transactions.
- **Delete semantics:** `204`; subsequent `GET` is `200 null`; delete-when-none remains `404`; re-create works.
- **Authorization/privacy:** `manage_planning` required (`403` without); scoped planner limited to visible categories; hidden category create/read/delete all `404` (no leak); cross-budget category `404`; deactivated member `404` while history is preserved.
- **Validation:** negative/zero/over-Int64 amount, invalid enum, malformed date, missing required date/recurrence, out-of-range priority, negative minimum, nonexistent category.
- **Concurrency:** deterministic last-writer-wins; exactly one row per category.

## Verdict
**TARGET CONTRACT READY WITH CAVEATS** — full CRUD, scoped authorization, month snooze/resume, immutable decision history, export/transfer preservation, and money-safety invariants are locked and tested. Weekly cadence and optional optimistic conflict rejection remain documented caveats.
