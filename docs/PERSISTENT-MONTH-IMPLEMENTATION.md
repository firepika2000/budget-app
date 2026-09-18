# Persistent monthly planning — next implementation boundary

Status: **IN PROGRESS — dated provider routing implemented; closure/rollover work remains**. This does not declare v0.9 complete.
Authority: PRODUCT-SPECIFICATION.md §§7.1–7.4 and APPLICATION-ARCHITECTURE.md.
Checkpoint inspected: `aecf712`, `codex/development`. Human acceptance pending; **DO NOT RETEST**.

## Established behavior and evidence

- Live assignment already stores dated, balanced allocation postings. `d8567e9` removes the obsolete
  future-month rejection, retaining all-date cash, scope, delegated and optimistic-version guards.
- `753fa39` prevents historical Smart Funding from reusing money allocated later. Its response
  separates selected-month RTA observations from the real spendable funding limit.
- Live summaries reconstruct category carry from dated allocations, transactions/splits and card
  reserve events. `aecf712` bounds historical ORM hydration without changing their financial meaning.
- Demo assignments and summaries now consume the exact dated projection. Replacement is category
  AND month scoped, negative carry is preserved, and future assignments consume all-date cash
  without overwriting current-month Assigned. See the production routing checkpoint below.
- Demo seed now has explicit account/category opening observations at 2025-10-01, dated allocations
  and chronological posted activity; financial display totals are derived from those facts. The
  command-routing and monthly read migration below is still required. Do not silently reinterpret
  an arbitrary difference as real income or a real historical transaction.
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

#### Persistence foundation: 0029_cash_rollover_history

This additive checkpoint records policy provenance only. It does **not** activate absorption,
change new-budget defaults, expose a selectable setting, or claim rollover engineering complete.
Every pre-existing budget receives a version-zero `carry_category_deficit` baseline effective
0001-01-01, explicitly sourced as `legacy_migration` with no fabricated user actor. The whole
supported date domain is intentional: imported transactions can predate budget creation. Only
metadata is inserted; existing financial rows and observations are unchanged. Backfill batches
are bounded at 500 budgets. Fresh budgets created while this integration gate remains closed keep
existing behavior; the future activation step must establish their explicit baseline too.

History stores budget, policy, effective month, ordered version, source, actor and timestamp.
Unique budget/version and first-of-month/policy/source/actor constraints protect stored shape.
Multiple revisions for the same future month can coexist so changing a pending choice does not
erase its audit history. The eventual service must lock the budget, compare expected policy version,
append rather than update/delete, reject past/current effective transitions, and invalidate stale
allocation previews when a change affects planning. A policy decision is not an allocation.

Baseline-only downgrade preserves all financial rows. Downgrade **refuses** if real policy decisions
exist, rather than deleting history and silently changing historical meaning. Use compatible
backup recovery to a new destination for that case. Recovery tests include nonempty policy history
in complete PostgreSQL row equality and actual age-encrypted backup/restore.

Remaining activation gates: a canonical effective-history projection shared by every balance guard,
summary/report and provider; mixed cash/credit/refund/split and historical-edit characterization;
new-budget absorb default with explicit household choice; scoped settings/audit API and shared UI;
stale/concurrent commands; populated migration/restore and full native production acceptance.
Do not ship a policy toggle backed only by this table or absorb balances only inside the Plan UI.

#### Boundary projection foundation (activation still gated)

`cash_rollover.project_rollover_effects` and `BudgetCore.CashRolloverProjection` consume canonical
category deltas and signed unfunded-credit attribution (credit-category activity plus recorded
reserve funding/release events). They are pure; they do not post financial transactions/allocations.
Seventeen shared vectors prove cumulative credit carry is not reclassified as cash in later months,
cash absorption happens once, refund/split treatment, prospective policy changes, pending-version
selection, leap/year/final-supported-month boundaries, and exact integer cancellation/overflow.
Sparse event/policy/next-month boundaries avoid iterating thousands of empty calendar months.

At each entering-month boundary, before that month's assignment/activity, cash deficit is
`max(min(cumulative_unfunded_credit_delta, 0) - category_available, 0)`. This is derived from actual
funding attribution, not a guessed fraction of negative Available or a current-month-only label.
An absorb policy yields an equal category carry increase and Unassigned decrease; credit deficit
is retained under existing card/debt semantics. Carry policy creates no effect. The policy effective
at that boundary is retained even if a later setting changes. A user edit to an old actual fact can
recompute the amount under the same historical policy; policy selection does not freeze bad data.

The existing Swift period projection can consume a complete derived effect set separately from
allocation postings. Effects alter carry/RTA, never user Assigned or Activity, and duplicate
category/month effects are rejected. Known future effects reserve already-spent cash in all-date
Unassigned, just like existing future allocations, without changing the historical dated RTA.
This is explicitly tested; no forecast income funds an effect.

Next integration must choose a consistent complete known-fact horizon (including the next boundary
and pending policy changes), stream authorized canonical repository inputs, apply the same effects
to every category/RTA guard and report, and prove full application-service behavior. Neither Live
nor Demo currently supplies policy effects to normal operations, so absorption remains **inactive**.
Do not infer production rollover completion from these pure-vector/package tests. No new migration
is introduced by this projection checkpoint; the policy-history head remains 0029.

### D. Shared presentation and closure

Production composition tests navigate months, edit an assignment, return, reload, inspect history,
and verify current spendable cash versus future reservations. Include restricted/delegated members,
archived resources, token rotation and stale/concurrent edits. Run backend, PostgreSQL races, shared
vectors, package, native XCTest and focused XCUITest using the approved Beta/Simulator only.

Checkpoint each coherent green change; commit/push and continue. No merge/tag. Human acceptance is
consolidated later, not a reason to stop independent engineering or request repeated QA now.

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

## Dated projection foundation — not yet a production provider

BudgetCore `PlanningPeriodProjection` now consumes validated balanced allocations and canonical
posted category/inflow activity. It separates dated RTA from all-date cash, derives month-specific
Assigned/Activity/carry/Available, and returns a replacement assignment bound to that snapshot's
month. Explicit opening observations have a supported boundary; earlier queries fail rather than
manufacturing history. Gregorian date-only parsing supports years 0001–9999 without timezone drift.
Checked two-word integer accumulation permits exact cancellation beyond intermediate Int64 range,
while every published monetary field and aggregate must still fit Int64.

Package tests consume the period fields of all six server operation scenarios. This is not a claim
that the package posts accounts, computes credit reserves, authorizes commands, persists state, or
that Demo passes the full scenarios. Those responsibilities remain at the canonical service/provider
boundary. Do not route production through this component until the input ledger and opening fixture
are complete and the full observation contract passes. In particular, do not adapt global Demo totals
into fictitious month records merely to use the component.

Verification: **44 Core + 49 API tests pass; 94 native XCTest pass**, Xcode 27 Beta 27A5252f build/test
on preserved iPhone 17 Pro Max/iOS 27 `3ABD861E-D38D-4AFD-A356-959266051564`.
Logs `/tmp/budget-dated-projection-package-verified.log`, `/tmp/budget-dated-projection-native-verified.log`.
Backend unchanged since **392 pass**. Next related correctness investigation: Demo refund attribution
currently sums positive events across all cards and ignores earlier releases; reproduce with shared
server/native command vectors before migrating that data into dated observations.

## Related corrections before provider migration

`bdfa497` fixes that refund investigation's three proven defects: cross-card attribution, repeated
release and split refunds exceeding remaining reserve. All 15 shared command vectors pass through
server and native adapters; **395 backend pass, zero skips**. Full dated/seed parity remains open.

The allocation-history correction records actual command deltas, dates, actors and IDs instead of
recreating assignments from category totals on every snapshot or inventing a $50 transfer. Opening
fixture observations are deliberately not presented as user history. Assignment replacement, moves,
Smart Funding, initial owner assignments and existing request/allowance mutation helpers record their
actual movements. Whole-operation visibility prevents exposing a private source through one visible
destination. Reads preserve history identity and dates regardless of selected month/persona.

This journal is a migration dependency, **not** an event-sourced provider or a claim of monthly
planning completion. Global category totals still drive current financial commands, seed account/card
provenance remains incomplete, and the existing allocation-version/concurrency model still needs
provider parity. Do not feed this command-only history into the dated projection as if it included
all fixture opening balances. The financial golden observation now checks balanced command postings,
not an invalid identity equating assignment totals with cash after spending.

## Production deterministic fixture ledger

The ordinary Demo constructor now installs explicit opening account balances and category purposes
at 2025-10-01. Opening cash equals Unassigned plus those purposes; opening card debt is explicitly
unfunded. Eleven historical months execute dated assignment commands before their actual expenses;
September executes the stated assignment plan, then its posted transactions chronologically. Credit
reserve attribution is generated by the same posting path rather than populated independently.
The shared BudgetCore projection derives September Assigned/Activity/Available from these facts.

This intentionally replaces inconsistent Demo-only display numbers; no Live values are changed.
Groceries now shows the actual $125 posted purchase, not an unrelated hardcoded $482.64 activity.
The dining example posts its actual $268.40 expense against $220 assigned, preserving a real $48.40
overspending example. The allowance example is an explicitly posted September 12 transaction, not
a future scheduled marker masquerading as actual account activity. Actual forecast schedules remain
separate. Stable fixture operation IDs/dates survive reload/reset; fresh Demo construction installs
no opening/history. No difference between old display fields is turned into income or a transaction.

Native proof reconstructs every account Working/Cleared balance from opening plus transactions,
compares every category against the exact dated projection, reconciles cash to purposes/reserves/new
unfunded debt, verifies deterministic identities and rejects planning queries before the explicit
opening boundary. Historical request metadata/action attribution and full command/read routing are
still separate unfinished work; this is not a declaration of full provider parity. Next route all
month-specific assignments, available-funds guards, summaries and date edits through these dated
facts, with the six complete provider command vectors and production month-navigation coverage.

## Production dated routing checkpoint

The native production repository and snapshot path now consume all seven shared period command
scenarios (not just package-level projection fixtures). A seventh scenario proves that October
funding cannot fund a September card purchase; a later September assignment funds only a later
purchase. The server adapter verifies the identical expected account/category/reserve observations.
Both adapters still consume all fifteen original financial scenarios.

Plan summaries, assignment replacement, Move Money date guards and Smart Funding use dated facts.
Smart Funding keeps historical RTA separate from globally spendable cash. Card purchases evaluate
category availability on their date; refunds evaluate dated net reserve attribution and payments.
Transaction date edits reproject affected periods; failed edits restore original accounts/categories,
transactions and reserve events instead of recalculating the old purchase under changed funding.
Void/reversal projection explicitly retains both the immutable original and its opposite dated
posting. A stronger production test caught an incorrect lifecycle filter before this routing
checkpoint was published; it would have counted only the reversal and overstated category money.
Regressions now cover both cash/cards across months and subsequent purchase/refund reserve netting.
Reconciled balance is explicitly nullable until a reconciliation, independent of cleared balance.
Fresh category creation now records its group metadata, fixing a snapshot force-unwrap crash found
when the full period adapter first exercised fresh production snapshots.

The production UI regression exposed another genuine defect: Previous/Today/Next were automatic
buttons in one List row; tapping Previous left the label at October and reopened October's value.
The controls now use independent native borderless button behavior and accessible labels/IDs.
The test covers September edit → October edit → September preserved → October preserved → November
→ Today, not merely an isolated assignment view. Pre-fix evidence is retained in
`/tmp/budget-period-ui-month-reproduction.log` and `/tmp/budget-period-integration-native-verified.log`.

Remaining closure boundaries are explicit: Demo still reports a fixed allocation version rather
than complete optimistic-concurrency parity; shared Plan should explain later-month reservations;
effective-history cash rollover is not implemented. Complete reconciliation input/date/adjustment
parity and calendar-independent test clocks still require audit. These are not reasons to undo
dated observations or mark the mission complete. Historical request metadata/action history and
the production Local Device provider remain separate work. Human Live is not migrated.

Final checkpoint verification: **396 backend tests pass, zero skips; 44 BudgetCore + 49 BudgetAPI;
101 native XCTest + 4 production XCUITests pass**, Xcode 27 Beta 27A5252f on preserved simulator
`3ABD861E-D38D-4AFD-A356-959266051564`. Build/test and diff check PASS. Evidence:
`/tmp/budget-period-integration-{backend,package,native-complete}.log`.

## Independent work remains available

### Versioned allocation commands — implementation checkpoint

Source audit after `f686a20` found Demo summary/history/Smart Funding serialized version 1;
assignment and Move Money ignored their supplied expected version. Live checks the locked budget
version before assignment delta/no-op evaluation and increments once per appended operation.
Live Smart Funding creates ONE operation with one Unassigned debit and all category credits.
Do not implement Demo parity by incrementing a counter once per target in the existing loop.

The following boundary is now implemented (verification recorded in the mission ledger):

- Preserve dated projection and existing fixture provenance. Fresh provider version starts at zero;
  deterministic fixture operations establish their explicit baseline. Reads never advance a version.
- Validate expected version at the actual synchronous mutation boundary. A stale no-op also conflicts;
  a current no-op neither creates history nor advances the version. Preserve resource/capability checks.
- Represent compound funding as one logical operation with stable identity, actor, date, source, note,
  balanced postings and ONE version increment. Validate all proposals and the combined prospective
  projection before publishing any part of the command. Reject the entire operation on failure.
- History must group the complete operation, not expose a partial compound operation through a
  visible destination. Its API `allocation_version` is the current budget concurrency token, as in
  the server contract; do not invent a per-operation historical version field in the public payload.
- Assignment, moves, Smart Funding and other actual allocation commands must invalidate outstanding
  previews consistently. Existing legacy test literals `expectedVersion: 1` are not valid evidence:
  adapters should use the observed token, while new adversarial tests deliberately send stale tokens.
- Prove one winner from two commands using the same token, refusal after intervening changes even
  if money returns to the prior values, atomic multi-target funding, no-op semantics, reload/history
  identity, whole-operation privacy and unchanged account/reconciliation/card observations.
- Run shared financial/period vectors and actual production month/move/funding UI tests; retain the
  server's PostgreSQL race proof. No new migration is needed merely for deterministic-provider parity.

Reconciliation input/date/consent parity was corrected in `5be09de`; a bounded authoritative cutoff
observation for partially visible histories remains separate follow-up. Forecast scope (`bed7c93`)
and chronological lows (`f686a20`) are now verified. These corrections do not complete prospective
cash rollover, clocks or the Local Device provider.

### Dated versus spendable Unassigned — summary and shared Plan

The monthly API now additionally reports optional `all_date_unassigned_minor` (canonical existing
cash plus all recorded allocation postings) and `funding_limit_minor` (the same minimum of
nonnegative dated/all-date Unassigned used by Smart Funding). The dated `ready_to_assign_minor`
is unchanged. Schedules do not enter either observation. Releasing a future assignment restores
current available funding without rewriting historical Assigned/Activity/Available.

Global observations are null unless both account/category scopes are unrestricted and the member
can view account balances. They are not inferred from a partial household. Swift decodes their
absence/null for older or restricted servers. Demo derives them from the existing exact period
projection, and the shared Plan labels the dated observation, Smart Funding limit and (when
different) all-month Unassigned with a later-allocations/posted-activity explanation. The UI does
not falsely name the difference “future reservations”: later actual inflows can also explain it.
This changes no assignment permissions, transaction accounting or manual-command semantics.
No migration; server restart and app rebuild required when eventually adopting. No human retest.

### Cash/card classification prerequisite

Native reproduction after `556c8d3` proved that Demo's `min(overspent, creditSpent)` heuristic
classified a cash deficit as credit debt after an earlier fully funded card purchase. A matching
server test uses real reserve events and correctly reports cash overspending, including a later
partial refund. Demo now reads the category attribution already recorded by its canonical posting
path, aggregates signed selected-month reserve changes, and matches Live's net credit/funded/cash
classification. It does not alter account balances, reserves, transaction posting or rollover.
Regression covers refunds, refund deletion, edits, void/reversal, and mixed-funded splits.
This fixes a classification prerequisite, not prospective rollover policy or uniform clocks.

Full structured export fidelity, bounded hydration in other reports, actual Docker/Compose recovery,
Local Device/import dependencies and the remaining roadmap are not closed by the current checkpoints.
The commercial purchase-model decision is external; this planning work is not blocked on it.

### Server rollover consumers (policy UI/default still gated)

`cash_rollover_repository.cash_rollover_effects` is the canonical ledger-to-projection adapter.
It streams scalar rows from five sources (allocations, direct/split on-budget transactions,
payment-category reserve activity, spending-category funding attribution), and selects the latest
version for each effective month. Retained storage scales with occupied category/month pairs,
not transaction count. No-policy/carry-only history avoids a ledger scan. A category-specific guard
can restrict to that category without changing its result; report resource scope is applied before
aggregation. This internal helper does not authorize; callers must do so.

`ready_to_assign_balance` debits effects, `category_available_balance` adds effects, and monthly
summaries/Plan Performance add them to carry, never Assigned or Activity. All-date guards use the
full known-fact horizon, including pending policy boundaries; dated guards only use effects through
their month. No schedule income is consumed. The same ordinary budget lock protects competing
allocations after absorption. Current scopes also apply to previously unfiltered reserve events.

Next: supply equivalent historical policy facts/effects in Demo's actual repository and every
command preflight; then implement prospective policy commands, stale-preview invalidation,
shared settings and explicit new-budget defaults. Do not expose an operational setting before
these providers agree. Broader Plan Performance hydration is still a separate bounded-memory gap.

### Demo rollover consumers — historical reporting gate remains

Following the server checkpoint, Demo now loads optional effective policy history into the actual
repository and derives rollover from its explicit fixture opening, dated allocations and on-budget
transactions/splits with recorded signed credit funding. A supplied through-date bounds both facts
and effects; global command preflights include all pending boundaries and additional allocations.
Transfers/schedules/tracking transactions do not become category rollover activity. Legacy no-history
construction remains unchanged; no user setting/default has been exposed. Request approval now
checks the same dated projection and stages its allocation before changing the request status.

Native production-service evidence covers exact dated/global balances, denial without mutation,
read neutrality, split/move/deletion recomputation, refund recovery, credit debt isolation, later
purchase funding and pending/superseded policy history. The projection is not a second money ledger.
Full historical reporting parity remains open: Demo Plan Performance currently builds only one
selected-month point, independent of the requested report range. Replace that with exact partial-
period observations before exposing policy settings. Retain private/scoped observations and do not
claim historical series acceptance from single-month summary tests.

### Historical Plan report correction following `e7959aa`

The recorded Demo historical-report gap is now implemented: report periods come from the requested
inclusive start/end range, not selected Plan month. Partial-month carry includes activity/allocations
before the first reported day, and absorption remains a month-boundary effect rather than Activity.
Purpose totals include recorded card funding/releases/payments, while spending excludes those reserve
changes and retains signed refunds. Archived purposes remain historical facts. Restricted categories
and accounts are scoped before aggregation and household Unassigned is hidden.

Each request prepares its dated ledger once, then reuses those immutable inputs for period snapshots;
date parsing/fact hydration/rollover derivation are not repeated per month. Range validation mirrors
the server's ordered 600-month limit. Demo's explicit opening is the earliest supported history, so
unsupported older months do not acquire invented balances. Transaction browsing no longer creates
an unrelated 200-year report to map DTOs; it uses the same scoped mapper directly.

Native and FastAPI contract coverage uses the same concrete split/move/card/refund scenario with
exact historical and partial-period values. Further tests preserve archived history, prove hidden
versus shared account scope, and cross rollover boundaries with a different selected Plan month.
No user policy setting/default or human-data migration is included. Continue the prospective policy
command/version/settings work; this report correction does not close the full production mission.

### Prospective owner policy API following `09a8ae6`

The server now has GET/PUT `/api/v1/budgets/{id}/cash-rollover-policy` and bounded GET `/history`
(`limit` 1...100, optional exclusive `before_version`). Current observation contains `current_month`,
`current_policy`, `policy_version`, `allocation_version`, and `pending` effective-month/policy/version
records. History preserves source, actor and timestamp, and returns `next_before_version` when needed.
Ordinary reads select only the latest revision per effective month rather than load every revision.

PUT takes `policy`, `effective_month`, `expected_policy_version`, `expected_allocation_version`.
The household owner is required, consistent with creation/settings ownership. It locks the ordinary
budget row, checks both versions, refuses current/past/non-month-start dates, and appends a real change.
No-ops preserve tokens/history, but stale no-ops still refuse. A real decision increments the allocation
token to invalidate pending funding previews, not an allocation or transaction. Candidate projection
is validated before commit; any supported-range failure rolls back baseline, decision and token.
No existing historical policy row is overwritten. A missing legacy baseline is recorded as version 0
with `legacy_migration` provenance and no invented actor only when the first real choice is appended.

Native settings and new-budget defaults are not exposed yet. Implement the same versioned command
in Demo and the credential-refresh-aware Live application-service path, with production settings
coverage, before final activation. Human Live remains untouched; this requires the existing 0029
schema in deployed environments and does not automatically migrate any database.
