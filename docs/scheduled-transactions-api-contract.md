# Scheduled / Recurring Transactions — Locked Server API Contract

Contract the production scheduled-transactions UI depends on. Verified by `server/tests/test_scheduled_transactions_contract.py` (15 tests) + `test_planning.py` at `codex/v0.4.0-stabilization`.

## Fundamental invariant
A scheduled transaction is a **future obligation/expectation**. It may feed forecast output, but it **never** mutates actual account balances, category activity, allocations, credit-card reserves, or spendable cash until explicitly **realized** into an actual transaction. **Future income is forecast-only and never spendable.** Money stays exact `Int64` minor units.

## Data model (`scheduled_transactions`)
| Field | Type | Rules |
|---|---|---|
| `id` | uuid | server-assigned |
| `budget_id` | uuid | scope |
| `account_id` | uuid | required; on-budget if a category is set; must be open and in scope |
| `destination_account_id` | uuid? | set ⇒ **transfer**; must differ from `account_id`; no category; positive amount |
| `category_id` | uuid? | outflow/inflow category; forbidden on transfers and on tracking accounts |
| `name` | string(1..150) | used as the realized transaction's payee/label |
| `amount_minor` | int64 | **nonzero**; sign encodes direction (negative = outflow, positive = inflow); transfers positive |
| `next_date` | date | next occurrence (local calendar date) |
| `recurrence_unit` | enum | `once` \| `days` \| `weeks` \| `months` \| `years` |
| `interval_count` | int | `1..365` |
| `memo` | string(≤500) | |
| `is_active` | bool | `false` = disabled (excluded from list & forecast; cannot realize) |
| `last_realized_on` | date? | set on each realization |
| `created_by_user_id`, `created_at`, `updated_at` | — | audit |

Realized transactions carry `transactions.scheduled_transaction_id` (plain string) — provenance that **survives schedule deletion**.

## Endpoints (prefix `/api/v1/budgets/{budget_id}`)

| Method / path | Capability | Notes |
|---|---|---|
| `GET /scheduled-transactions` | `view_transactions` | Active only; filtered by account/category visibility |
| `POST /scheduled-transactions` | `manage_planning` | Create; scope + shape validated |
| `PUT /scheduled-transactions/{id}` | `manage_planning` | Full-object edit incl. `is_active`; scope re-checked; **last-writer-wins** (metadata, no version) |
| `DELETE /scheduled-transactions/{id}` | `manage_planning` | Removes the plan; **realized actuals preserved** (lineage string retained) |
| `POST /scheduled-transactions/{id}/realize` | **`create_transaction`** | Realizes the due occurrence; see below |

Errors are structured (`detail`) and consistent with the Swift client's decoder (string or `{message,…}`). Common: `403` (capability), `404` (missing / out of scope / cross-budget / deactivated), `409` (inactive schedule), `422` (validation / not due / credit-to-credit / unfunded card payment).

## Realization semantics (`POST …/realize`)
1. Requires **`create_transaction` now** (not the schedule's creator) and re-validates account/destination/category against the caller's **live** scope — permission revoked after creation blocks realization.
2. `409` if the schedule is inactive; `422` if `next_date > today` (not due; actuals can't be future-dated).
3. Creates exactly **one** actual transaction (two legs for a transfer, sharing a `transfer_id`) dated `next_date`, `is_cleared = false`, `payee_name = name`, `scheduled_transaction_id = schedule.id`.
4. Reuses the **same** engine as manual entry — `add_purchase_reserve_events` for credit purchases, `add_payment_reserve_event` for transfers to/from a credit card (including the "payment not fully funded" `409`), credit-to-credit rejected. **No credit-card accounting is duplicated in the scheduler.**
5. Advances the schedule **atomically under a row lock** (`SELECT … FOR UPDATE`): `last_realized_on = next_date`; `once` ⇒ `is_active = false`; otherwise `next_date = next_occurrence(...)`. Because the occurrence advances inside the lock, the **same due occurrence cannot double-post** — a second realize returns `422` (advanced to future) or `409` (once, now inactive).
6. Returns `ScheduledRealizationResponse { scheduled_transaction_id, transaction_ids[], realized_on, next_date, is_active, last_realized_on }`.

## Recurrence & date semantics
`next_occurrence` (pure, `app/planning.py`) uses the **local Gregorian calendar** and clamps day-of-month: Jan 31 + 1 month → Feb 28 (or 29 in a leap year); Feb 29 + 1 year → Feb 28. `once` yields no next occurrence. Weekly/annual supported (`weeks`/`years`); month-granular sinking funds use `months`. No UTC shifting — dates are calendar dates, not timestamps.

## Forecast integration
Forecast (`GET /forecast?through=…`, horizon today..+366) expands active schedules into projected occurrences: expenses reduce and income increases **projected** totals, kept distinct from actual/current money. Disabling or deleting a schedule removes it from the forecast; editing amount/date/recurrence updates it deterministically. Scheduled items are **not** included in historical Insights/Spending until realized.

## Delegated authority
Creating a schedule posts nothing to the allocation ledger and does not change any member's `available_to_assign` — scheduling neither consumes nor expands delegated authority. At realization, normal server-side delegated limits, category rules, and scope checks apply (a delegated member can only realize within their permitted accounts/categories). Insufficient-delegated-funds warnings, if desired, stay forecast-only.

## Supported vs deferred
- **Supported:** create/read/list/edit/delete/disable/realize; one-time and recurring (daily/weekly/monthly/annual via unit+interval); inflow/outflow/transfer; scheduled credit purchase & card payment & refund via the shared engine; next-occurrence calculation; realize-into-actual with lineage; idempotent no-double-post.
- **Deferred (documented, non-blocking):** explicit **end date / occurrence count** (model has none — schedules run until disabled/deleted); **auto-materialization** (realization is explicit/confirmed, not a background job); "automatic vs confirmed" flag on lineage (all realizations are explicit today); optimistic **version** on edit (LWW, safe because pre-realization edits move no money); per-occurrence skip.

## Verdict
**SCHEDULE CONTRACT READY WITH CAVEATS** — full CRUD + realization, money-safety invariants, idempotent no-double-post, scope re-check at realization, credit/transfer correctness, and recurrence boundaries are locked and tested. Caveats (end-date/count, background auto-materialization, edit versioning, per-occurrence skip) are deferred and do not block the P1 UI. A schedule cannot double-realize and future income cannot become current spendable money.
