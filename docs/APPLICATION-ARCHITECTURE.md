# Application Architecture

Status: Stage 2 provider-neutral application boundary. The product authority remains
[`PRODUCT-SPECIFICATION.md`](PRODUCT-SPECIFICATION.md), and executable accounting expectations
remain in [`FINANCIAL-CONFORMANCE.md`](FINANCIAL-CONFORMANCE.md).

## Runtime flow

```text
Canonical SwiftUI workspace (Home / Plan / Activity / Accounts / Insights)
                              |
                              v
          Account / Planning / Transaction / Schedule services
                              |
                              v
       capability-oriented, async repository command contracts
                    /                         \
                   v                           v
       Live server adapter             Deterministic adapter
       (API DTO translation)           (in-memory persistence)
                   |                           |
                   v                           v
       authoritative server engine     golden-vector-conformant state
```

There are no Live and Demo application services. The same product operation types, validation,
application errors, services, workspace store, editors, and five-tab product UI are used for both.
Provider selection remains at composition time in `RootView` and `BudgetWorkspaceStore`.

## Ownership

- `ApplicationServices.swift` owns provider-neutral operation and observation vocabulary,
  product-level validation, application errors, and focused orchestration services.
- The repository protocols express async provider capabilities. They do not contain URLs, HTTP
  verbs, authentication tokens, SwiftUI bindings, or persistence implementation types.
- `LiveWorkspaceCommandRepository` owns translation from canonical operations to existing
  `BudgetAPI` transport DTOs. The server ledger, allocation, credit, reconciliation, authorization,
  schedule realization, and persistence remain authoritative.
- `DemoWorkspaceDataSource` is the deterministic adapter. `DemoStore` is its current in-memory
  persistence and projection implementation. Its migrated mutations now enter through the same
  services and are checked against the same JSON vectors as the server.
- SwiftUI owns navigation and editable drafts, but emits canonical operations. It does not branch
  on the financial provider or perform authoritative accounting.

## Canonical contracts introduced in Stage 2

Operations cover account opening, assignment, allocation movement, transaction entry/edit/delete,
splits/refunds, account transfer/card payment, reconciliation, schedule create/edit/delete, and
schedule realization. All money is `Int64` minor units. Derived chart geometry remains outside this
mutation boundary.

The focused financial observation contains account balances, category Assigned/Activity/Available,
credit liability/reserve/unfunded debt, Unassigned, on-budget cash, net worth, transaction count,
and allocation conservation. It is the provider-neutral result used by the conformance runner.
Existing workspace read screens still incrementally consume `BudgetAPI` response models; replacing
every read DTO is deliberately deferred to avoid a risky all-at-once UI rewrite.

## Conformance and differences

`server/tests/financial_vectors/v1.json` is loaded directly by both provider runners:

- `server/tests/test_financial_golden_vectors.py` translates operations through the HTTP/server
  adapter.
- `ios/BudgetAppTests/FinancialGoldenVectorTests.swift` translates those same operations through
  `BudgetApplicationServices` and the deterministic repository.

The deterministic dataset is fixed and local by design; Live requires authentication, connection
configuration, and may surface network availability. Those are composition/provider concerns, not
different meanings for financial operations.

## Remaining migration boundaries

- Workspace read snapshots and several not-yet-migrated features (category/group metadata,
  requests, targets, Smart Funding, household/delegation administration, and reports) still use
  API-shaped read or supplemental command models.
- `DemoStore` still contains deterministic persistence/projection arithmetic. It is not product
  authority; the shared vector suite prevents migrated behavior from diverging silently. A future
  on-device repository must use an authoritative shared domain engine rather than copy this store.
- `BudgetCore/MonthlyBudget.swift`, `DelegatedBudget.swift`, and `Insights.swift` remain legacy or
  quarantine candidates. Production does not import them, but deletion waits until all useful
  package invariants are represented at the canonical boundary. `BudgetCore.Money` remains a useful
  exact-money value-type candidate.
- Future-month planning and rollover policy remain Stage 5 gaps. The Stage 2 contracts do not make
  current server limitations canonical.

## Error boundary

Services expose `BudgetApplicationError` categories (`insufficientFunds`, `permissionDenied`,
`invalidOperation`, `notFound`, `conflict`, and `temporarilyUnavailable`). Adapters may preserve
provider diagnostics in their underlying logs, while UI receives product-oriented failure meaning.
