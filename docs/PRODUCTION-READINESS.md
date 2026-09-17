# Production readiness mission ledger

Updated: 2026-09-17. Active branch: `codex/development`.
Mission starting checkpoint: `e3f2922`. Production release readiness: **IN PROGRESS**.
Human acceptance: **HUMAN REQUIRED — HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

This ledger tracks engineering evidence separately from release approval. Main remains at
`c5494dd`; historical version tags do not establish acceptance for subsequent development.
Checkpoint completion is followed by the next unblocked engineering task.

| Gate | Status | Evidence and remaining work |
|---|---|---|
| PRODUCT | IN PROGRESS | v0.4–v0.7 history is preserved in existing acceptance/closure documents. v0.8 terms, interest classification, projections, strategies and payoff UI exist. Complete v0.8 review before planning/import/local-provider work. Reconcile older roadmap numbering with the approved mission explicitly. |
| FINANCIAL | IN PROGRESS | Shared financial vectors and exact-money server engine exist. `d7a702d`: 10 shared strategy vectors, 18 focused Python tests and 6 Swift projection tests passed. Extreme-input safety, remaining projection vectors and report reconciliation still require closure proof. |
| SECURITY | IN PROGRESS | Server capability/resource guards and regression suites exist. Extend adversarial matrix across reports, projections, imports and future providers; rerun relevant PostgreSQL/privacy gates. |
| DATA | IN PROGRESS | Source migration chain ends at `0027_interest_class`; human Live remains at `0020_payee_identity_repair`. Repeat populated upgrade and encrypted attachment-inclusive restore into disposable destinations. Production Local Device storage remains open. |
| RELIABILITY | IN PROGRESS | Credential authority is shared by long-lived Live services. Existing native/backend suites provide regression evidence; concurrency, offline failures, cancellation and release-wide regression remain open. |
| PERFORMANCE | IN PROGRESS | Static production call-path audit proves up to seven report requests per owner workspace snapshot plus category/account fan-out. This is a request-count baseline, not a wall-clock or payload measurement. Implement demand loading and instrument request counts/payloads before closure. |
| UX | IN PROGRESS | Shared production shell, onboarding, scalable payee selection and focused Insights exist. Restore reachable report filters, audit error/loading states, and provide actionable missing-debt-terms navigation. |
| ACCESSIBILITY | IN PROGRESS | Existing accessibility-sized/dark-mode navigation tests passed at earlier checkpoints. Repeat on changed report screens; audit VoiceOver amounts, charts, controls and custom ordering. |
| PLATFORM | IN PROGRESS | Xcode 27 Beta and existing iPhone 17 Pro Max/iOS 27 are required. Preserve Simulator data. Release configuration, lifecycle, platform scope and Apple integrations need closure. |
| COMMERCIAL | BLOCKED | HUMAN PRODUCT DECISION REQUIRED: paid download versus free Demo plus non-consumable Lifetime Unlock. Preferred documented hypothesis is the latter; it adds restoration/offline/revocation complexity while allowing evaluation. Paid download reduces entitlement complexity but prevents pre-purchase evaluation. No StoreKit implementation before decision. Independent engineering continues. |
| APP STORE | IN PROGRESS | Commercial strategy includes positioning and draft screenshot narrative. Verify current Apple primary sources when preparing privacy/distribution artifacts. Signing, developer enrollment, final identity/pricing and submission remain human/external actions. |
| OPERATIONS | IN PROGRESS | Developer launcher and advanced server documentation exist. Audit production deployment, migration/recovery, attachment key backup, monitoring and normal-user server management. |
| HUMAN ACCEPTANCE | HUMAN REQUIRED | Preserve prior accepted workflows; consolidate only changed/unverified workflows later. No claim of new human acceptance from automation. DO NOT RETEST during autonomous run. |

## Current execution order

1. Finish v0.8: demand-loaded reports with current credentials, correct cache invalidation and
   visible loading/retry states; exact projection edge cases; report/privacy/accessibility audit.
2. Complete broad v0.8 automated closure, including disposable PostgreSQL migrations/recovery.
3. Reconcile roadmap sequencing with the approved planning/import/local-data mission, preserving
   the existing normal-user server distribution requirement and financial invariants.
4. Continue the highest-priority unblocked engineering gate through release-candidate readiness.

## Human data and migration ledger

Never run migration, destructive, scale or restore tests against human Live. Known unapplied chain:
`0021_scheduled_payee_id` → `0022_report_query_indexes` → `0023_category_favorites` →
`0024_member_lifecycle` → `0025_request_lifecycle` → `0026_debt_terms` → `0027_interest_class`.
Recheck the source graph before migration work. Use disposable populated PostgreSQL databases and
restore to new destinations. Preserve human attachments, transactions and reconciliation history.

Native toolchain: `/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer`.
Preserved Simulator UDID: `3ABD861E-D38D-4AFD-A356-959266051564` (reverify runtime before use).

## Checkpoint evidence

- `50ec90a`, `4b6f5be`, `bfeff14`: exact multi-debt engine, authorized projection endpoint and
  shared native scenario UI. Earlier verification is recorded in the development handoff;
  it is not a fresh release-wide result.
- `d7a702d`: shared strategy vectors; focused Python 18 passed, Swift projection 6 passed.
- `e3f2922`: strategy evidence and static Insights hydration baseline documented.
- Paid-off strategy boundary correction: the new shared `all_debts_already_paid` fixture first
  reproduced Python returning `non_amortizing`/1,200 payments while Swift returned paid off.
  Python now returns paid off, zero payments, zero cost and the scenario start date. Eleven shared
  vectors pass; focused Python 18 passed, Swift projection 6 passed on Xcode Beta; full backend
  suite passed with the 11 explicitly PostgreSQL-gated cases skipped. No migration required.

Engineering-controlled gates are not all PASS. This is not yet an App Store release candidate.

Recorded-interest privacy checkpoint: the HTTP regression reproduced hidden-category and mixed-split
interest contributing to a restricted member's totals (13,000 instead of 1,000 minor units). The
report now applies transaction category visibility before every interest aggregate and coverage date,
while preserving independently authorized account balances. Analytics/delegation tests: 68 passed.
Full backend regression passed; 11 PostgreSQL-only concurrency tests remain explicitly skipped in
this run and require the disposable PostgreSQL closure gate. No Swift or migration changes.

Payoff recovery checkpoint: the production screen now opens the shared Debt Terms editor from
missing inputs and account actions, then recalculates after dismissal. Native UI verification
exposed and corrected a lazy-section sheet presenter and Demo's accidental inheritance of Net
Worth's tracking filter. Debt reporting now includes authorized tracking loans and stable history
regardless of that toggle, matching Live. Native XCTest: 82 passed, including money-neutral terms
recovery and tracking parity; production recovery XCUITest: 1 passed; Swift package: 33 BudgetCore
and 45 BudgetAPI passed. Simulator test builds succeeded with Xcode 27.0 (`27A5252f`) on the preserved
iOS 27 iPhone 17 Pro Max. Human acceptance remains pending. No migration required.
