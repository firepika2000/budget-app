# Application architecture

This document describes the enforced v0.4 runtime architecture. Financial invariants and server-side authorization remain authoritative; see `financial-invariants.md` and the architecture audit for the point-in-time debt inventory.

## Application state machine

```text
BudgetApp
  -> process-stable AppSession
  -> selected source (deterministic or configured live server)
  -> connection/authentication state
  -> household and visible budgets
  -> persisted active budget selection
  -> ActiveBudgetShell
  -> BudgetWorkspaceView
       Home | Plan | Activity | Accounts | Insights
       Profile & Settings (available from every tab)
```

`BudgetApp` constructs one `AppSession` with `@StateObject`. `AppSession.route` is the only root routing decision. It owns source selection, credential validation, authentication state, the budget collection, active-budget selection, and a once-per-active-scene activation latch. Child views consume state and send intents; they do not independently refresh credentials.

Authentication fields are owned by `AuthenticationFlowView`, below the route boundary. Keystrokes can therefore update form state without invalidating the root state machine. Secrets and refresh material remain in Keychain-backed session storage, not view state.

## Active-budget product shell

A valid persisted budget selection enters `ActiveBudgetShell` directly. The Budgets list is a chooser and creation surface, not a permanent navigation parent. Profile & Settings provides budget switching, budget creation, household access, source/server context, and sign out. All five tabs use production views in deterministic and live modes.

Each tab owns a `NavigationStack`. On iOS 27 the selected tab can change before a lazily created stack is materialized, leaving the content region blank. `BudgetWorkspaceView` intentionally keys the `TabView` by the selected tab to guarantee materialization. This is a narrowly documented identity boundary; editor drafts remain modal and locally owned. Removing it requires a successful production-composition regression on the affected OS, not a source-only cleanup.

## Data and repository boundary

```text
production SwiftUI views
  -> BudgetWorkspaceStore (snapshot, refresh, mutation coordination)
       -> authenticated API source -> self-hosted server -> PostgreSQL
       -> deterministic source -> API-shaped in-memory fixture
```

Both sources feed the same workspace, features, editors, and API-shaped models. Editors do not own a server URL or bearer token; they submit operations through the shared workspace store and reload the authoritative snapshot after successful mutation. Exact monetary source-of-truth values are signed `Int64` minor units. Floating point is limited to derived presentation geometry such as chart angles.

The remaining v0.4 boundary debt is that `BudgetWorkspaceStore` still dispatches some mutations to its concrete live or deterministic source internally. That compatibility seam is centralized and does not create separate view hierarchies, but a later repository-protocol expansion should make every command polymorphic without changing accounting semantics. It is not permission to duplicate financial logic in Swift.

## Form ownership

Transient editor input is owned by the stable editor/sheet root, normally as local `@State` or a dedicated `@StateObject`. Opening an editor initializes a draft; typing changes only that draft; Cancel discards it; Save validates and converts currency text to exact minor units before submitting one operation. Refreshes occur after successful persistence, not on each keystroke. Derived bindings must have real setters and no editor may bind to a disposable navigation parent.

## Security and accounting boundaries

- The server enforces household membership, capabilities, resource scopes, and deny-by-default privacy.
- Client capability checks improve discovery but never authorize a request.
- Transfers change account location without creating income, spending, or category activity.
- Schedules and forecasts remain money-neutral until server realization creates an actual transaction.
- Allocation postings balance exactly; future income is not Ready to Assign.
- Credit-card liability, category availability, and payment reserve use the existing server engine.
- Demo behavior may mimic the contract for deterministic product testing but is not an authority for live accounting definitions.

## Verification layers

1. Swift package and backend tests prove domain, contract, authorization, migration, concurrency, and financial invariants.
2. Native XCTest hosts application and workspace composition to prove routing, ownership, and feature integration.
3. XCUITest launches the built product and exercises actual navigation, focus, keyboard entry, and fresh-budget first-use surfaces. This layer is mandatory for regressions whose failure depends on UIKit/SwiftUI presentation behavior.

Automation is necessary but does not mark v0.4 accepted. A human must still complete the documented iOS 27 Simulator and authenticated live-server journeys before release, merge, or tag.
