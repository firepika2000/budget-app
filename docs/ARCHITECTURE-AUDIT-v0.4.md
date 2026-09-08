# v0.4 Application Architecture Audit

Status: Phase A audit at `cc88b5b`. This document records the current system and the safe refactor
order. It is descriptive, not evidence of human acceptance.

## Executive finding

The financial engine, server authorization model, exact-money contracts, migrations, and most feature
views are coherent and should be protected. The repeated acceptance failures originate primarily in
application composition: lifecycle work is coupled to SwiftUI presentation, the workspace repository
abstraction covers reads but not mutations, deliberate identity replacement hides navigation defects,
and interactive journeys are tested through hosting controllers rather than XCUITest.

This is repairable without a rewrite or a financial migration. The target is one process application
coordinator, one active-budget context, one production workspace, one complete repository contract,
stable local form models, and explicit production-journey tests.

## Current runtime map

```text
BudgetApp (@StateObject AppSession.production)
  └─ RootView (@EnvironmentObject AppSession, root-owned AuthenticationFormState)
      ├─ deterministic → ActiveBudgetShell → BudgetWorkspaceView.demo()
      ├─ missing/invalid server → ServerSetupView
      ├─ connecting → connecting state
      ├─ setup required / no token → AuthenticationView
      └─ connected → ActiveBudgetShell
          ├─ valid active budget → BudgetWorkspaceView(budget).id(budget.id)
          └─ no valid selection → BudgetSelectionView → BudgetCreationView

BudgetWorkspaceView (@StateObject BudgetWorkspaceStore)
  └─ TabView.id(selectedTab)
      ├─ NavigationStack → Home
      ├─ NavigationStack → Plan
      ├─ NavigationStack → Activity
      ├─ NavigationStack → Accounts
      └─ NavigationStack → Insights
          └─ Profile & Settings sheet from Home
```

The server boundary is `BudgetAPI.APIClient`. `AppSession` constructs clients for discovery,
authentication, identity, and budget discovery. `BudgetWorkspaceStore` constructs another client for
live workspace reads/mutations. Demo reads are adapted into API DTOs by `DemoWorkspaceDataSource`, but
demo mutations are selected with concrete-type downcasts inside `BudgetWorkspaceStore`.

## State ownership inventory

| State | Current owner and lifetime | Mutation authority | Observers | Recreation risk | Classification |
| --- | --- | --- | --- | --- | --- |
| Source, server, connection, credentials, profile, budgets, active budget | `AppSession.production`, process lifetime; injected once by `BudgetApp` | `AppSession` public intents plus root lifecycle | Root, source settings, workspace/profile | Low for the object; lifecycle tasks can repeat | Global application state |
| Credential refresh operation/generation/invalidation | Private `AppSession` tasks and counters | `AppSession` only | Presentation observes published result | Low after `4579278`; callers must remain centralized | Global security state |
| Scene validation gate | `RootView @State`, root-view identity lifetime | Root task and scene callback | Root only | Medium: coupled to SwiftUI modifier lifetime | Application lifecycle coordination |
| Authentication draft | `RootView @StateObject AuthenticationFormState` | Authentication controls | AuthenticationView | Low while Root identity survives; no explicit focus model | Local flow state with root lifetime |
| Active workspace snapshot, filters and plan month | `BudgetWorkspaceView @StateObject BudgetWorkspaceStore`, active-budget lifetime | Store plus feature views | All five tabs and editors | Recreated on budget/source change; intentionally correct for budget change | Active-budget state |
| Demo domain fixture | `DemoWorkspaceDataSource` owns `DemoStore` within workspace store | Store downcasts and DemoStore methods | Indirect through API-shaped workspace state | Recreated on app launch/source switch | Repository state |
| Tab selection | `BudgetWorkspaceView @State` | TabView | Workspace | `TabView.id(selection)` replaces all tab navigation state each switch | Local shell state |
| Feature presentation flags | Individual feature views | Owning view | Local sheet/navigation | Lost if tab/workspace identity is replaced | Local presentation state |
| Editor drafts | Individual editor `@State` values | Editor | Editor only | Stable within sheet; lost on parent identity replacement | Local editing state |
| Persistent source/server/active budget | `UserDefaults` | AppSession | AppSession initialization | Stable; validated budget selection depends on successful list load | Application persistence |
| Access/refresh tokens | Keychain through `TokenStoring` | AppSession | AppSession only | Stable and generation guarded | Secure persistence |

Demo and Live do not change the ownership of AppSession or feature views. They do currently change the
workspace store's implementation path internally.

## Ownership conflicts and lifecycle hazards

1. `RootView` still coordinates source/auth state with `.task` and `scenePhase` modifiers. `cc88b5b`
   adds a once-per-active gate, but the coordinator remains embedded in view lifetime rather than an
   explicit application state machine.
2. `AppSession` exposes several correlated published properties. Root derives presentation by checking
   them in priority order, allowing theoretically invalid intermediate combinations. An explicit route
   enum would make transitions atomic and testable.
3. `configureServer` performs discovery and may call `loadBudgets`; root validation delegates back into
   `configureServer`. The behavior is centralized in one object but responsibilities are conflated.
4. `BudgetWorkspaceView.task` owns workspace hydration. Reappearance can reload legitimately, but the
   store lacks a load-generation guard equivalent to AppSession and can publish an obsolete response
   after budget/source replacement.
5. Workspace errors are one global string. A failure in any parallel snapshot request can replace the
   entire feature state without a typed loading/empty/restricted/error model.
6. Authentication focus has no modeled identity. The form values were stabilized in `cc88b5b`, but a
   literal keyboard regression is still required because hosted state mutation is not focus behavior.

## Repository and Demo/Live divergence

The same Home, Plan, Activity, Accounts, Insights, Profile, and editor views are used for both sources.
That is a strong foundation. The divergence is below the views:

- `WorkspaceDataSource` defines only `snapshot`.
- Live reads and every live mutation are implemented directly in `BudgetWorkspaceStore` using
  `APIClient` and stored URL/token values.
- Demo mutations are selected through more than twenty `dataSource as? DemoWorkspaceDataSource`
  branches and mutate `DemoStore` directly.
- Demo analytics contain client-side fixture calculations. They intentionally produce API DTOs but do
  not yet guarantee every server semantic (notably net refund aggregation and some split/report edge
  cases) through one repository contract.
- Editors accept server URL/token even though they also receive the shared workspace store. This leaks
  transport concerns into presentation and enables divergent mutation routes.
- The fallback `token ?? "demo"` convention is safe only because demo mutations branch first; it is an
  implicit source discriminator and should be removed from presentation.

Target: a complete `BudgetWorkspaceRepository` protocol containing snapshot and mutation intents, with
`LiveBudgetWorkspaceRepository` and `DeterministicBudgetWorkspaceRepository`. The store coordinates
state and delegates every operation without concrete downcasts. Views know neither token nor URL.

## Navigation findings

- Active budget is correctly the application context after `4579278`; no normal Budgets parent exists.
- Each tab currently owns one `NavigationStack`, which is the appropriate navigation boundary.
- `TabView.id(activeTab)` was introduced for an iOS 27 lazy-materialization defect. It also destroys all
  tab-local navigation and presentation state on every tab change. It is a tactical workaround, not the
  desired final architecture.
- `BudgetWorkspaceView.id(budget.id)` intentionally replaces the workspace when the active budget
  changes. That identity replacement is appropriate and should remain documented.
- Sheets generally create their own `NavigationStack`, which is appropriate for modal editor flows.
- `BudgetDetailView` duplicates the old multi-feature budget UI, is compiled, and has no construction
  site outside its declaration. It is dead architecture and a future regression risk.
- Profile & Settings is reachable only from Home. It is global application chrome and should be
  consistently reachable without depending on one feature's navigation toolbar.

## Forms audit

Transaction, allocation, request, account, category, target, schedule, transfer, reconciliation, and
policy editors keep draft values in local `@State` and submit explicitly. Money fields use editable
strings and parse to exact `Int64` minor units. No editor stores financial source-of-truth as `Double`.

Risks:

- Parent `TabView` replacement can destroy a presented editor or its draft.
- Several forms initialize defaults in `onAppear`; repeated appearance can overwrite a partially edited
  draft unless guarded by an empty/current-value check.
- Authentication needed a longer-lived form object because its parent presentation changes during
  source resolution. Focus itself remains unverified by XCUITest.
- Some large one-line editor implementations obscure identity and initialization review.

Target: local observable draft models for complex editors, initialization exactly once, explicit
cancel/save semantics, and no global mutations before save.

## Capability, empty, loading, and error states

- Structural actions are generally gated with server-provided `budget.can(...)` capabilities; backend
  authorization remains authoritative.
- Fresh Accounts and Plan now have owner-capable instructional CTAs and restricted-member explanations.
- Activity, Insights, scheduled transactions, and household screens contain empty content, but their
  loading/error/empty states are not represented by a common typed state.
- Home can appear structurally sparse for a new budget but does not become blank.
- Live failures never intentionally fall back to Demo.
- Root distinguishes configuration, connecting, setup, authentication, selection, and workspace, but
  does so through nested property checks instead of one state-machine value.

## Backend boundary

The audited backend routes consistently enter authenticated household/budget-scoped dependencies and
the iOS client uses budget-scoped endpoints. Authorization, allocation, credit-card, schedule,
analytics, and migration behavior are protected. No backend compatibility change or data migration is
required for this refactor. PostgreSQL concurrency behavior is outside the touched composition layer.

## Testing gaps

Current layers:

- Domain: strong Swift and backend accounting/authorization suites.
- Repository/state: good API contract, AppSession generation, deterministic store, and migration tests.
- Composition: several `UIHostingController` render-signal tests exercise Root/workspace structures.

Missing layer:

- There is no XCUITest target and no `XCUIApplication` journey.
- Hosted tests mutate Swift state directly; they cannot prove keyboard focus, tap routing, accessibility
  discovery, modal dismissal, or application relaunch persistence.
- Source-string assertions protect architecture textually and can pass when runtime composition fails.
- The current scheme's machine-local edits must not be mistaken for shared test configuration.

Critical XCUITest journeys are Demo → Live → literal email/password typing, invalid refresh → Sign In,
fresh Accounts/Plan activation, tab switching, Profile budget/source switching, and relaunch restoration.

## Protected components

Do not redesign during alignment:

- `BudgetCore` exact-money and allocation semantics.
- Server allocation, reconciliation, credit-card reserve, scheduled realization, delegation, analytics,
  authorization, audit, and migration logic.
- Existing `BudgetAPI` wire compatibility.
- Production Home/Plan/Activity/Accounts/Insights feature behavior and shared editors.
- Generation-guarded, single-flight credential rotation and terminal 401 invalidation.

Any discovered financial defect is documented and handled separately. No financial defect identified by
this audit requires stopping the composition refactor.

## Target architecture

```text
BudgetApp
  └─ ApplicationCoordinator / AppSession (one process-stable owner)
      ├─ SourceRepository (deterministic or live configuration)
      ├─ CredentialSession (live only; single-flight and generation guarded)
      ├─ Household + budget directory
      ├─ validated active-budget identity
      └─ atomic AppRoute
          ├─ sourceSetup
          ├─ connecting
          ├─ serverBootstrap
          ├─ authentication
          ├─ budgetSelection / firstBudget
          └─ workspace(ActiveBudgetContext)
              └─ ActiveBudgetShell
                  ├─ stable TabView with one NavigationStack per tab
                  └─ global Profile & Settings presentation
                      └─ BudgetWorkspaceStore
                          └─ BudgetWorkspaceRepository
                              ├─ Deterministic repository
                              └─ Live API repository
```

The coordinator owns transitions; views render routes and send intents. Source choice changes repository
implementation, never feature composition. Budget identity intentionally creates a new workspace context.
Tab selection does not. Editors own drafts and invoke repository intents only on save.

## Refactor order and gates

1. Introduce an explicit, atomic application route and lifecycle activation API in AppSession. Preserve
   wire behavior and existing generation tests.
2. Make Profile & Settings a shell-level presentation and make source/budget switch intents explicit.
3. Complete the workspace repository protocol, first wrapping current Live behavior, then moving Demo
   mutations behind the same protocol. Preserve every existing store test at each step.
4. Remove transport arguments and demo token fallbacks from views/editors.
5. Replace `TabView.id(selection)` with stable tab identity only after an iOS 27 composition test proves
   titles, toolbars, empty states, and navigation all materialize.
6. Remove unreachable `BudgetDetailView` after a global construction-site check and green workspace tests.
7. Move complex editor drafts to explicit local models where repeated initialization is possible.
8. Add an XCUITest target and critical journeys. Literal keyboard acceptance remains human-gated even
   after automated UI coverage.
9. Update `ARCHITECTURE.md`, roadmap wording if needed, and live acceptance evidence.

Each step is a separate green, pushed checkpoint. No database migration, backend API break, financial
engine rewrite, main merge, or v0.4 tag is part of this plan.
