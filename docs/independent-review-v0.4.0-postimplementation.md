# Independent Post-Implementation Verification — v0.4.0 stabilization

Reviewer role: independent verifier (product, UX, financial-domain, security).
Target: `codex/v0.4.0-stabilization` @ `f6c8d37` ("Complete v0.4 architecture correction and financial workflows"), diffed against the v0.3.0 baseline `87517c1`.
Method: full source trace of the delta (server routes, models, migrations, authorization, allocation/credit engines, SwiftUI workspace, API client, tests) **plus executing the server test suite locally**. Bank sync remains out of scope and was not touched.

**Execution evidence:** I created a venv, installed the server deps, and ran the suite: **64 passed** (`pytest -q`), including the delegated-authority, advanced-ledger, analytics, and existing-data migration-backfill suites. The iOS app could not be built on this Windows host (no Xcode); Swift verification is by source trace and by reading the shipped test files, not by running the app. This caveat is reflected in the conditions below.

---

## EXECUTIVE VERDICT

The v0.4.0 work is a **genuine, well-structured architectural correction**, not a cosmetic pass. All nine baseline findings were addressed in the actual code — schema, authorization, and client — and the two highest-risk ones (delegated monetary authority, demo/live unification) are implemented the right way and backed by tests that assert the real invariants. The delegated-boundary tests in particular prove the exact hole I flagged is closed: a delegate holding `assign_money` is still 403-blocked from household Ready-to-Assign, reallocations conserve the pool, and hard-limit/approval rules enforce.

Remaining issues are **hardening, consistency, and coverage** items, not correctness defects in the shipping path. There is one latent trap (a BudgetCore Insights calculator whose definitions disagree with the server) and a few defense-in-depth gaps worth closing before GA.

**Classification: READY WITH CONDITIONS.**

---

## FIXES VERIFIED

1. **Demo/live unification (was P0-1).** `DemoRootView`, `DemoActivityViews`, `DemoHouseholdViews`, `DemoInsightsViews` are deleted. There is now one product surface: `BudgetWorkspaceView` with a `WorkspaceDataSource` protocol. `DemoWorkspaceDataSource` synthesizes the *same* `APIModels` types the live client returns and feeds the *same* screens (`LiveHomeView/LivePlanView/LiveActivityView/LiveAccountsView/LiveInsightsView`); `BudgetWorkspaceStore` routes every mutation through either the demo store or the real `APIClient` via one code path (`createTransaction`, `updateTransaction`, `moveAllocation`, `decideRequest`, etc.). Demo is now a data/service implementation, not a second app. `RootView` demo branch is `BudgetWorkspaceView.demo()`.

2. **Delegated monetary authority (was P0-4).** New `DelegatedBudgetPolicy(authority_minor, pool_category_id, allow_category_creation, allow_reallocation)` + `DelegatedCategoryRule(rule_kind ∈ {hard_limit, soft_target, approval_gated}, minimum_minor, maximum_minor)`. Enforcement is real and layered:
   - `upsert_assignment` **hard-blocks any user with a policy** (403) — delegates cannot assign from household RTA.
   - `transfer_allocation` for a delegate requires `allow_reallocation`, requires **both** categories `delegated_user_id == self`, and enforces `approval_gated` (block), `hard_limit` source-minimum, and `hard_limit` destination-maximum.
   - Authority funding is a single balanced ledger op (`ready_to_assign → pool`); increases require household RTA, decreases require the pool to hold the clawback; both under budget lock + version check.
   - The invariant holds: a delegate can only move money among their own categories, so their controlled total is conserved at `authority_minor` and cannot be increased. Verified by `test_delegated_reallocation_stays_inside_boundary_and_enforces_rules` (assign_money bypass → 403; move conserves 20000→15000; minimum → 409; hidden-parent move → 403/404; stale/invalid authority change → 409) and `test_delegated_member_can_create_only_own_scoped_category`.

3. **Reconciliation integrity (was P1-3).** Creating an adjustment now requires `manage_budget_structure` (not merely `reconcile_account`), closing the mint-money hole. Added `expected_cleared_balance_minor` optimistic guard and `with_for_update` on the account. Positive-cash reconciliation becomes an explicit, auditable real-money transaction; credit reconciliation changes debt without creating RTA. Verified by `test_positive_cash_reconciliation_becomes_explicit_real_money_then_allocates`, `test_credit_reconciliation_changes_debt_without_creating_ready_to_assign`, `test_reconciliation_rejects_stale_balance_and_restricted_adjustment`.

4. **Transaction mutation model (was P0-2).** New `PUT/DELETE /transactions/{id}` with `edit_transaction`/`delete_transaction` capabilities. Both: reject transfer legs and reconciled transactions, re-check account+category scope via `can_access_resource`, restrict to the creator unless `manage_budget_structure`, recompute credit-card reserve events (delete + re-add), and write immutable before/after/delete audit rows (`TransactionChange`). Client exposes detail → edit/delete with full field support (payee/account/date/category/splits/memo/cleared/flag/tags/attachment metadata). Verified by `test_transaction_edit_recalculates_category_reports_and_account`, `test_reconciled_transaction_cannot_be_edited_or_deleted`.

5. **Request/approval flow (was P0-3).** Backend state machine was already correct and is unchanged; the client is now wired: `LiveRequestDetailView` performs approve / partial / request-changes / reject through `decideFinancialRequest`, with source-category selection, version passing, and action-history display. Partial-approval-moves-once auditability verified by `test_partial_request_approval_moves_existing_allocation_once_and_is_auditable`.

6. **Insights driven by real data (was P0-5, P1-1, P1-2).** New `analytics_routes` (`/reports/spending`, `/reports/income-spending`) run date-ranged queries with account/category/group/payee/member/type/cleared/tracking filters and return `transaction_ids` for drill-through. Permission-scoped via `visible_resource_ids` with 404 on out-of-scope IDs. Client `LiveInsightsView` offers 30d/60d/90d/3m/6m/YTD/1y/custom, a filter sheet, and true drill-through: report → category → contributing transactions → detail → edit → save → recalculated report. Old hardcoded/contradictory demo figures are gone. Verified by `test_spending_report_is_explainable_and_split_aware`, `test_income_spending_excludes_transfers_and_recalculates_after_edit`.

7. **Rolling periods are real.** `BudgetWorkspaceStore.reportRange` computes genuine rolling windows; `FinancialPeriodCalculator` (BudgetCore) implements rolling-days/month/YTD/calendar-year/custom with a tested previous-period helper.

8. **Migrations safe from a populated v0.3.0 DB.** Chain intact: `0011_credit_attribution → 0012_delegated_policies → 0013_transaction_history → 0014_transaction_metadata`. New tables are additive; `0014` adds `tags`/`attachment_metadata` as `NOT NULL DEFAULT '[]'` and `flag` nullable — safe for existing rows. Existing-data backfill suite (`test_allocation_migration`) still passes.

9. **Capability model extended coherently.** `edit_transaction`, `delete_transaction`, `manage_own_categories` added to `ALL_CAPABILITIES` and mapped into the legacy `contribute`/`manage` bundles.

---

## FIXES PARTIALLY VERIFIED

- **iOS runtime behavior.** All client wiring is present and internally consistent in source, and the BudgetCore/BudgetAPI test targets exist, but I could not compile or run the app (no Xcode on this host). The end-to-end SwiftUI flows (drill-through, edit-and-recalc, approval sheet) are verified structurally, not at runtime. → *Condition: run the iOS build + XCTest in CI.*
- **Smart Funding delegate safety.** `commit_smart_funding` relies on `assign_money` and, for a restricted delegate, `month_summary` returns `ready_to_assign = 0`, so it yields no proposals (409). Safe in practice, but unlike `upsert_assignment`/`transfer_allocation` it has **no explicit `DelegatedBudgetPolicy` block** — defense-in-depth gap (see P1).

---

## FIXES NOT VERIFIED

None. Every one of the nine baseline findings is addressed in code.

---

## NEW P0 DEFECTS

None found.

---

## NEW P1 DEFECTS

- **P1-a — BudgetCore `InsightsCalculator` disagrees with the server and is not the source of truth.** `incomeVersusSpending` counts *any* positive amount as income (including refunds), whereas the server (and the shipping UI, which uses the server reports) counts only inflows-to-RTA (`amount>0 AND category_id is None AND not splits`). `spendingByCategory` also ignores split-only transactions (`categoryID != nil`), which the server includes. Today the shipping Insights path does not use this calculator, so there is no user-visible bug — but it is a live library type with tests asserting the *wrong* definition, and wiring it into any screen later would silently produce numbers that don't reconcile to the server. Recommend either deleting it or aligning it to the server definitions and adding a cross-check test. (`Sources/BudgetCore/Insights.swift`.)

- **P1-b — `commit_smart_funding` lacks the explicit delegate guard.** Add the same `DelegatedBudgetPolicy` 403 check used by `upsert_assignment` so the invariant is enforced structurally rather than incidentally through a zero-RTA summary. (`server/app/budgeting_routes.py`.)

---

## SECURITY / AUTHORIZATION FINDINGS

- **IDOR / scope:** assign, move, transaction create/edit/delete, reconcile, and both analytics reports all re-validate account/category ownership against `can_access_resource` / `visible_resource_ids` and return 404 for out-of-scope IDs. Report filters reject out-of-scope `account_id`/`category_id`. No client-only restriction was found guarding money movement.
- **Analytics leakage:** a restricted delegate's reports are constrained to their visible categories; household income (category-less inflow) is not visible to them (the visibility predicate excludes `category_id is None` when categories are restricted). No aggregate-based inference path surfaced.
- **Privilege escalation:** reconciliation adjustment now needs `manage_budget_structure`; delegates are blocked from RTA assignment and from touching non-owned categories; approval requires `approve_request` and is version-guarded.
- **Minor:** `commit_smart_funding` delegate guard (P1-b). Reconciliation adjustments are recorded as ledger transactions but are **not** written to `TransactionChange` history (they're created directly), a small audit-trail asymmetry.

## DELEGATED-BUDGET FINDINGS

Sound. Finite authority is modeled as a funded pool category plus a hard `authority_minor`, conserved by construction because delegates can only reallocate within their own categories and are barred from RTA. Rules cover locked minimums, category maximums, and approval-gated withdrawal. Concurrency is protected by budget lock + `expected_allocation_version`. Edge behaviors are sensible: authority reduction is refused (409) when the pool can't cover the clawback (parent must consolidate first). Minor: a delegate can archive their own pool category via `update_category` (money is preserved and the delegated summary stays correct, but it disappears from the month view) — cosmetic, worth a guard.

## RECONCILIATION FINDINGS

Correct and now permission-bounded. Positive and negative discrepancies handled; stale cleared balance rejected via `expected_cleared_balance_minor`; credit semantics preserved (debt changes without minting RTA); adjustment gated behind household authority and made explicit/auditable in the ledger. Minor: the client computes its `expected_cleared_balance` without a `through_date` filter while the server filters `occurred_on <= through_date`; identical for the default (today) but could raise a spurious 409 if a user reconciles to an earlier through-date with later cleared transactions present.

## TRANSACTION FINDINGS

Create/edit/delete are correct, scope-checked, and audited. Edits recompute category activity, account balances, and credit reserves (via delete + re-add of reserve events) and are proven to recalculate reports (`test_transaction_edit_recalculates_...`). Reconciled and transfer-leg transactions are immutable. Full metadata (flag/tags/attachment metadata) is persisted. Not separately asserted: editing a *credit-card purchase's* amount and re-verifying the reserve delta (the reserve recompute path is exercised for cash edits and reconciliation, but a dedicated credit-purchase-edit assertion would harden it — see coverage gaps).

## INSIGHTS FINDINGS

Now real, explainable, and drill-through-complete. All required ranges plus custom are present and actually re-query. Every reported total carries `transaction_ids`, so each number reconciles to source rows, and tapping through reaches the editable transaction with recalculation on return. Transfers are excluded from income/spending. The only concern is P1-a (the unused, divergent core calculator).

## STATE-MANAGEMENT FINDINGS

Single source of truth per workspace: `BudgetWorkspaceStore` holds the loaded snapshot and every mutation calls `refresh()`, which re-fetches accounts, transactions, summary, reports, delegated budget, and forecast together — so an edit/approval/move invalidates Home, Plan, Accounts, Insights, and forecast consistently. No independently cached financial truth was found in the client (balances derive from `accountBalances` with a transaction-sum fallback). Note: `store.transactions` loads full budget history into memory and report drill filters client-side by id — correct, but a scale/perf consideration, not a correctness issue.

## MIGRATION FINDINGS

Upgrade-safe from a real v0.3.0 database: additive tables, defaulted non-null columns, intact revision chain, and passing backfill tests. Downgrades drop the new tables/columns cleanly. `DelegatedBudgetPolicy.updated_at` is `NOT NULL` without a server default, which is fine for a new empty table (ORM sets it on insert) but would need attention only if rows were backfilled in-migration (they aren't).

## TEST-COVERAGE GAPS

- No explicit **concurrent double-approval** race test (the code is protected by `with_for_update` + version, so the second approver should get 409 — assert it).
- No explicit test that a delegate **cannot Smart-Fund** from RTA (ties to P1-b).
- No **credit-card purchase edit** test asserting the reserve delta after changing amount/category (cash-edit and reconciliation paths are covered).
- No test upgrading a **populated** v0.3.0 database end-to-end through 0012–0014 (only fresh-schema + existing-backfill fixtures).
- No explicit **analytics permission-leakage** test for a delegate calling the report endpoints with a household-scoped filter (the scoping code is present and correct; a direct hostile-filter test would lock it in).

## RELEASE BLOCKERS

None at the code level. The server suite is green (64 passed) and the architectural invariants hold.

## POST-RELEASE IMPROVEMENTS

- Resolve P1-a (delete or realign the BudgetCore Insights calculator; add a server-parity test).
- Add the explicit delegate guard to `commit_smart_funding` (P1-b).
- Record reconciliation adjustments in `TransactionChange` for a uniform audit trail.
- Guard/rethink delegate archival of the pool category.
- Align client reconcile `expected_cleared_balance` with the server's `through_date` semantics.
- Add the five coverage tests above.

## FINAL RELEASE RECOMMENDATION

**READY WITH CONDITIONS.** The nine baseline defects are genuinely and safely fixed; the delegated-authority and demo/live corrections are the right architecture and are test-proven. Ship after: (1) CI runs the iOS build + XCTest to confirm the client compiles and its flows pass at runtime (I could not on this host); (2) closing the two P1 hardening items; (3) adding the concurrency/credit-edit/populated-migration coverage tests. None of these are correctness defects in the code as written — they are the difference between "verified correct by reading + server tests" and "verified correct end-to-end."

---

*Independent verification only; no product code was modified. The single change I made was creating a throwaway server virtualenv to execute the existing test suite.*
