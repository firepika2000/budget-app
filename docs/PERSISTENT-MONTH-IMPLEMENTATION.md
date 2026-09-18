# Persistent monthly planning — next implementation boundary

Status: **ENGINEERING DESIGN / IMPLEMENTATION REQUIRED**. This does not declare v0.9 complete.
Authority: PRODUCT-SPECIFICATION.md §§7.1–7.4 and APPLICATION-ARCHITECTURE.md.
Checkpoint inspected: `aecf712`, `codex/development`. Human acceptance pending; **DO NOT RETEST**.

## Established behavior and evidence

- Live assignment already stores dated, balanced allocation postings. `d8567e9` removes the obsolete
  future-month rejection, retaining all-date cash, scope, delegated and optimistic-version guards.
- `753fa39` prevents historical Smart Funding from reusing money allocated later. Its response
  separates selected-month RTA observations from the real spendable funding limit.
- Live summaries reconstruct category carry from dated allocations, transactions/splits and card
  reserve events. `aecf712` bounds historical ORM hydration without changing their financial meaning.
- Demo `assignMoney` still ignores `operation.month`; `DemoStore` mutates global category totals.
  Its snapshot repeats those totals for different planning months and manufactures allocation-history
  presentation rows for the selected month. That is not persistent period behavior.
- Demo seed account/category observations are not a complete dated transaction/allocation ledger.
  The visible seeded transactions alone cannot reconstruct all seeded balances. Do not silently
  reinterpret an arbitrary difference as real income or a real historical transaction.
- The legacy BudgetCore MonthlyBudget calculator is quarantined, not production authority. Existing
  shared financial command vectors are useful but do not yet prove multi-period behavior.
- No effective-period cash-overspending policy history exists. Current global policy fields on
  allowance plans are unrelated and must not be reused for household cash rollover.

## Required contract

1. Selecting another month never rewrites an earlier month. Assignment replacement is scoped to
   category AND month; allocating in October cannot replace September's assignment.
2. Existing cash can be reserved for a future month. Schedules and projected income are never
   spendable before canonical realization. All new allocations compete for the same remaining cash.
3. Dated observation and currently spendable cash are distinct values. Explain future reservations
   in shared UI rather than showing historical RTA as permission to spend it again. Do not simply
   replace every historical RTA with today's global value.
4. Cash overspending is represented once: either carried on its category or absorbed into the next
   period's Unassigned. Never carry the deficit AND separately reduce Unassigned for it.
5. Credit debt/reserves are not cash rollover. Mixed cash/card activity, refunds, splits, reserve
   changes and later coverage must be classified from canonical financial evidence, not from a
   guessed fraction of a negative category total.
6. Policy changes are prospective. Existing historical observations cannot be silently reinterpreted
   when a setting changes or when a migration is installed. The recommended default for new budgets
   is absorb-into-next-month; preserve legacy observations for existing budgets until an explicit
   prospective transition. Record actor and effective period.

## Safe delivery sequence

### A. Characterize the authoritative multi-period ledger

Add shared operation/observation vectors at the application-service boundary, not screenshot-only
fixtures. Include September/October/November assignment and replacement, future reservation followed
by present-month allocation refusal, scheduled income before/after realization, positive carry,
cash-only deficit, credit-only deficit, mixed activity/refund/split, and a prospective policy change.
Assert account Working/Cleared/Uncleared, reconciliation, Unassigned, Assigned/Activity/Available,
card liability/reserve/unfunded debt and balanced allocation history at every relevant step.
Reads and navigation must be money-neutral. Include an edit that changes a transaction's date.

First establish which vectors current Live satisfies; retain failing evidence for genuine gaps.
Do not change current carry semantics while merely adding period persistence to the other provider.

### B. Shared provider-neutral period projection

Define dated domain observations/events with exact checked minor units, explicit provenance and
canonical credit-reserve inputs. The future Local Device repository must use this authority rather
than copying DemoStore. Avoid a second ad-hoc cache of assigned/activity/available that can diverge
from transaction edit/delete, transfer or reconciliation services.

Replace Demo's incomplete global seed with a consistent deterministic ledger or explicitly model
fixture opening observations at a defined boundary. Any opening-observation approach must distinguish
fixture initialization from user financial commands and prove exact reconciliation with seeded
accounts/categories/cards. It cannot fabricate queryable history outside its supported boundary.
Keep the same production shell, services, editors and authorization behavior.

### C. Effective-period rollover and migration

Design persisted policy history and its audit attribution before adding a current-policy enum.
Specify how closed periods, prospective changes and edits to old transactions interact. Prefer
derivable, idempotent effects: refreshing a month must not repeatedly post rollover money. If effects
are persisted, classify them separately from user Assigned and preserve balanced accounting; if
derived, all availability guards and reports must consume the same canonical projection.

Use an additive, short-ID migration with populated legacy-preservation and downgrade/upgrade proof.
The human Live database remains at 0020; autonomous tests use disposable databases only. Extend
encrypted recovery equality to every new policy/event table. Do not migrate human Live.

### D. Shared presentation and closure

Production composition tests navigate months, edit an assignment, return, reload, inspect history,
and verify current spendable cash versus future reservations. Include restricted/delegated members,
archived resources, token rotation and stale/concurrent edits. Run backend, PostgreSQL races, shared
vectors, package, native XCTest and focused XCUITest using the approved Beta/Simulator only.

Checkpoint each coherent green change; commit/push and continue. No merge/tag. Human acceptance is
consolidated later, not a reason to stop independent engineering or request repeated QA now.

## Independent work remains available

## Characterization checkpoint — server adapter

`server/tests/financial_vectors/planning-periods-v1.json` now contains six fixed-clock operation
sequences: independent/future periods and replacement, a transaction date edit, legacy cash carry
and coverage, mixed card/cash/refund reserve observations, split/refund/transfer attribution, and
scheduled income before/after realization followed by future funding and reconciliation.
Accounts describe current authoritative balances; category/RTA observations explicitly select a
planning month. Funding limit is separate from the dated RTA observation. No report read/reload or
rejected assignment may change financial tables. The original twelve vectors remain unchanged.

The real server HTTP adapter passes all six; full backend **392 pass, zero skips**, including
disposable PostgreSQL/concurrency/migration/recovery and the original golden vectors.
Evidence `/tmp/budget-period-vectors-full.log`. These are characterization fixtures, not a claim
that Demo supports them yet, and they do not bless missing prospective rollover or the classification
of carried credit deficits. Next implement the exact dated domain projection needed by the
deterministic/local repository migration; do not weaken fixture expectations to fit global totals.

Full structured export fidelity, bounded hydration in other reports, actual Docker/Compose recovery,
Local Device/import dependencies and the remaining roadmap are not closed by the current checkpoints.
The commercial purchase-model decision is external; this planning work is not blocked on it.
