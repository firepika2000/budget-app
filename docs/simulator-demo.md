# v0.4.0 Simulator and live review

The Debug build opens a deterministic fictional household through the same `BudgetWorkspaceView` and `BudgetWorkspaceStore` used by authenticated operation. Demo data is ephemeral and is a repository fixture, not a security boundary or substitute for a live test.

## Deterministic mode

1. Open `ios/BudgetApp.xcodeproj`, select **BudgetApp**, and choose an iPhone on iOS 17 or later.
2. Run without arguments to open the shared five-tab product with the owner fixture.
3. Use `--demo-persona=alex` or `--demo-persona=mia` to launch a restricted member fixture.
4. Optionally add `--demo-screen=home|plan|activity|transaction|accounts|credit|insights` for a repeatable starting tab.

Walk through Home, Plan, Activity, Accounts, Insights, and Household. Create and edit an exact split; change its date/category and confirm Insights refreshes; move allocations; preview/commit Smart Funding; reconcile an account; approve a request partially; request changes; reject a request; and verify the child fixture cannot discover owner or sibling resources.

## Authenticated self-hosted mode

1. Start the backend and an empty disposable database using `server/README.md` or `server/compose.yaml`; apply `alembic upgrade head`.
2. Add `--live` to the Run arguments, bootstrap/login, create a household budget, and seed only test data.
3. Repeat every deterministic workflow. Confirm mutations survive relaunch and a second authenticated session sees the same state.
4. Exercise stale reconciliation and allocation/request versions from two clients; the second write must receive a conflict and reload.
5. Authenticate as each restricted household member and attempt direct resource identifiers belonging to the owner and a sibling. The server must deny them even if the UI route is constructed manually.

## Review checklist

- Check light and dark appearance, Dynamic Type, VoiceOver labels/order, reduced motion, empty states, loading, server errors, and offline/retry behavior.
- Confirm cash reconciliation adjustments change Ready to Assign, credit adjustments do not, and exact reconciliation creates no adjustment.
- Confirm transaction flags, tags, attachment metadata, splits, payee, memo, account, category, cleared state, and date persist after edit.
- Confirm every Insights number drills into contributing transactions and changes immediately after an edit.
- Confirm owner, spouse, teen, and child disclosure choices match the intended privacy policy.

The automated v0.4 verification device is iPhone 15 Pro Max, iOS 17.5. Do not tag the release until this human walkthrough is signed off. Bank synchronization and external financial-provider connections are not part of either mode.
