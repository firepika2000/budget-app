# Financial Conformance

Status: Stage 2 dual-provider executable baseline. The product authority is
[`PRODUCT-SPECIFICATION.md`](PRODUCT-SPECIFICATION.md); this document does not replace it.

## Purpose and authority

Budget App must not acquire a different accounting engine for each persistence provider. The
conformance suite records provider-neutral product operations and observable outcomes before the
Stage 2 repository/application-service migration begins.

The current server engine is the implementation baseline where it agrees with the product
specification. A passing test records current conformance, not permission to override the
specification. A documented conflict stays a gap until its scheduled product stage.

## Golden operation vectors

`server/tests/financial_vectors/v1.json` is a versioned list of scenarios. It contains only:

- symbolic references such as `checking`, `groceries`, and `card`;
- product operations such as account creation, assignment, money movement, transaction entry,
  transfer, reconciliation, scheduling, and realization;
- observations such as account balance, Unassigned, Assigned, Activity, Available, payment
  reserve, unfunded card debt, budget cash, net worth, transaction count, and allocation
  conservation;
- exact integer minor units.

It intentionally contains no URL, token, SQLAlchemy model, database identifier, SwiftUI state, or
wire DTO. `test_financial_golden_vectors.py` is the first provider adapter and translates those
operations to the server API. Stage 2 can relocate the fixture to a provider-neutral package when
the repository contract exists; it must not rewrite the scenarios to fit a provider.

An `observe` operation is a checkpoint. This makes intermediate truth—such as the state after an
assignment but before a move, or before and after schedule realization—part of the contract.

## Invariants

The executable suite and existing invariant tests jointly protect:

1. allocation postings balance to zero;
2. category moves preserve budget cash and Unassigned;
3. paired on-budget transfers preserve total budget cash and Unassigned;
4. split portions sum exactly and affect their categories without penny drift;
5. schedules and expected income are money-neutral until realization;
6. funded card spending reserves existing cash rather than manufacturing it;
7. tracking balances affect net worth but never Unassigned;
8. every amount in a golden vector is an integer minor-unit value;
9. reconciliation differences create explicit adjustment transactions;
10. categorized refunds restore Available without also increasing Unassigned.

The seeded property harness in `server/tests/test_invariants_property.py` independently recomputes
ledger, Unassigned, transfer, and split identities after randomized valid operations. Targeted
tests cover reserve explainability, overspending classification, delegated authority, approval
terminal states, and month rollover neutrality.

## Financial implementation map

| Implementation | Classification | Evidence and responsibility |
|---|---|---|
| `server/app/allocation.py` | **AUTHORITATIVE** | Exact allocation postings, zero-sum enforcement, Unassigned, category Activity and Available. |
| `server/app/budgeting_routes.py` | **AUTHORITATIVE application/API entry point** | Account openings, assignments, moves, transactions/splits, transfers, reconciliation, month observations, Smart Funding commit. It delegates core balances to allocation/credit services. |
| `server/app/credit.py` | **AUTHORITATIVE** | Payment-category creation and event-sourced purchase/refund/payment reserve attribution. |
| `server/app/planning_routes.py` and `server/app/planning.py` | **AUTHORITATIVE for implemented planning behavior** | Targets/recommendations, schedule persistence, forecast, and realization through normal transaction/transfer accounting. Forecast state is non-posting. |
| `server/app/analytics_routes.py` | **AUTHORITATIVE reporting projection** | Permission-filtered spending and income/spending semantics derived from authoritative transactions. It is not an allocation engine. |
| `server/app/models.py` | **AUTHORITATIVE persistence model** | Monetary columns use integer minor units (`BigInteger`); allocation and split constraints preserve exactness. |
| `ios/BudgetApp/ApplicationServices.swift` | **CANONICAL APPLICATION BOUNDARY** | Provider-neutral operations, observations, capability repositories, focused services, validation, and application errors. It does not implement the server ledger. |
| `ios/BudgetApp/BudgetWorkspaceView.swift` live data source/store | **LIVE ADAPTER / presentation state** | Translates canonical commands to server DTOs, loads server observations, and refreshes shared UI state. Display/chart derivations are not authoritative mutations. |
| `ios/BudgetApp/DemoStore.swift` through `DemoWorkspaceDataSource` | **DETERMINISTIC ADAPTER / FIXTURE PERSISTENCE** | Migrated mutations enter through shared services and its exact state transitions pass the same golden vectors. It remains non-authoritative in-memory persistence/projection code. |
| `Sources/BudgetCore/MonthlyBudget.swift` | **LEGACY / QUARANTINE CANDIDATE** | Pure monthly calculator duplicates Assigned/Activity/Available/Unassigned formulas. No production target imports it; only `BudgetCoreTests` exercise it. Preserve until Stage 2 proves replacement coverage. |
| `Sources/BudgetCore/Insights.swift` | **LEGACY SUPPORT / QUARANTINE CANDIDATE** | Pure reporting/date calculations, aligned with server refund/transfer semantics and tested, but not imported by the production iOS target. It is not financial mutation authority. |
| `Sources/BudgetCore/DelegatedBudget.swift` | **LEGACY / QUARANTINE CANDIDATE** | In-memory delegated allocation engine used by package tests, while production authority lives in server allocation/delegated routes. Do not delete until shared-service migration resolves ownership. |
| `Sources/BudgetCore/Money.swift` | **DOMAIN VALUE TYPE, currently package-local** | Exact `Int64` money arithmetic and currency validation; useful candidate for later shared domain work, but not currently used by the production iOS/server path. |

There is one server accounting engine composed of focused services, plus two independently mutable
Swift implementations. Stage 2 must preserve server semantics and eliminate the ability of Demo or
legacy calculators to invent a competing result.

## Known provider divergences

These are findings, not newly canonicalized behavior:

| Behavior | Server | Deterministic/Demo | Status |
|---|---|---|---|
| Categorized positive transaction | Restores category Activity/Available and does not increase Unassigned. | Same canonical transaction path restores the category once. | **CONFORMANT — shared vector** |
| Positive transaction deletion/edit | Rebuilds transaction and card attribution; ordinary positive transactions affect their destination once. | Exact reversal followed by canonical reapplication. | **CONFORMANT — native regression coverage** |
| Credit purchase reserve | Derives funded reserve from category availability and records attribution; refunds release attribution. | Canonical deterministic path derives and reverses per-transaction reserve attribution. | **CONFORMANT — shared vectors for funded/unfunded purchase and payment** |
| Credit-card payment | Transfer consumes payment reserve and rejects an unfunded payment. | Transfer consumes reserve and rejects an unfunded payment. | **CONFORMANT — shared vector** |
| Reconciliation adjustment | Explicit categorized-null transaction; on-budget cash changes Unassigned and tracking remains isolated. | Same observable consequences with explicit transaction. | **CONFORMANT — shared vectors** |
| Tracking transaction/category boundary | Rejects category effects from tracking accounts and excludes tracking from Unassigned. | Same boundary and opening-balance isolation. | **CONFORMANT — shared vector** |
| Future actual transaction | Rejects it and directs callers to planning. | Canonical deterministic transaction path rejects it. | **CONFORMANT for migrated entry path** |
| Assignment deficit | Rejects increasing assignments/category initialization beyond current Unassigned; real adjustments may make Unassigned negative. | Same rule; category creation no longer clamps the deduction. | **CONFORMANT** |
| Spending reports | Nets categorized refunds/splits and excludes transfers after visibility filtering. | Deterministic production projection now uses exact split attribution and nets refunds. | **CONFORMANT for current report contract** |

Static Demo seed totals are presentation fixtures and are not proof that the seed can be reproduced
from its transactions. Stage 2 should make seeded state enter through the same operations/services
or explicitly label immutable snapshot observations.

## Specification gaps

| Specification requirement | Current server | Current Demo | Conformance | Future stage |
|---|---|---|---|---|
| Cash overspending policy A or B, effective by boundary | Month summaries hard-carry prior category balances; no per-budget policy/effective history. | Static/month-light state; no durable boundary policy. | **GAP. Do not make hard-carry canonical.** | Stage 5 |
| Allocate existing money into future planning periods | Assignment endpoint rejects months after the current month. | Month state is shallow and not a persistent future ledger. | **CONFLICT. Rejection is not a golden rule.** | Stage 5 |
| Reporting classification separate from allocation destination | Transaction schema infers income/refund from sign/category/transfer; no first-class classification. | Same limitation, largely inferred from sign/category. | **GAP** | Transaction/domain completion |
| First-class payees | `payee_name` string only. | Payee string only. | **GAP** | v0.5 |
| Full account lifecycle | Partial close/archive behavior and metadata. | Rich sample metadata but incomplete authoritative lifecycle. | **GAP** | Later account lifecycle stage |
| Broad Activity/audit, complete reports, scenarios, on-device repository, realtime sync, backup/restore | Partial or absent by capability. | Some illustrative UI/data only. | **OUT OF STAGE 1** | Product roadmap |

Negative Unassigned itself is supported by server observations when a real negative reconciliation
adjustment reduces cash after all existing cash was assigned. The golden suite locks that meaning
without permitting expected income to cover it.

## Adding behavior safely

1. Start from the relevant product-spec rule and name the allocation and reporting consequences.
2. Add or extend a provider-neutral vector using integer minor units and symbolic references.
3. Add the operation once to each provider adapter; never encode a provider workaround in the
   fixture.
4. Add an independently calculated invariant when the operation moves cash, allocation authority,
   reserve, or debt.
5. Run all provider adapters. Treat disagreement as a defect or explicit specification gap.
6. Change authoritative production behavior only when the specification clearly requires it, and
   retain audit/concurrency/permission coverage.
7. Update this matrix with the resolved ownership and migration stage.

## Stage 2 boundary

Stage 2 should introduce application/domain services and a repository contract that consume these
operations, then adapt Live and Deterministic providers to them. It should not replace the server
ledger, redesign the UI, or add Personal Mode. The first closure target is the five Demo divergences
that can corrupt money: categorized refunds, positive edit/delete reversal, credit reserve rebuild,
card-payment reserve consumption, and reconciliation/Unassigned behavior. `BudgetCore` removal or
promotion comes only after those services and both provider adapters run the same vectors.
