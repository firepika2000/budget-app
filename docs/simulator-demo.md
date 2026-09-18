# v0.4.0 Simulator and live review

## Current autonomous verification environment (2026-09-18)

The walkthrough below is historical. For the current production-readiness run, use **only**
`/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer` (Xcode 27.0, `27A5252f`) and the existing
iPhone 17 Pro Max / iOS 27 Simulator `3ABD861E-D38D-4AFD-A356-959266051564`. Set `DEVELOPER_DIR`
explicitly for every `xcodebuild`/`xcrun` operation; the global developer selection may differ.
Do not erase the device, reset preferences, migrate human Live, or launch the stable Simulator.
Human acceptance is pending: **DO NOT RETEST** during the autonomous run.

For unattended native tests, a process-scoped `/usr/bin/caffeinate -i env DEVELOPER_DIR=... xcodebuild
...` prevents idle system sleep until that command exits without changing permanent power settings.
It does not override a deliberate lid-close/system sleep. A 2026-09-18 XCTest tap timeout coincided
with confirmed host Maintenance Sleep intervals; inspect `pmset -g log` before attributing a long
event-synthesis timeout to app code. Do not shorten or weaken UI assertions to hide it.

Run native tests serially on this device. Xcode can spend up to ten minutes collecting Simulator
diagnostics after failed test cases; distinguish completed test assertions from the final command
exit status. Keep logs/results and report failures even when a focused rerun passes.

If macOS signs a generated Swift package test bundle unsuccessfully because of Finder/resource-fork
metadata, build with `swift test --scratch-path /tmp/<new-test-build-directory>` under the same Beta
toolchain. Do not disable signing or remove attributes from user data to make tests pass.

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

The historical automated v0.4 verification device was iPhone 15 Pro Max, iOS 17.5; it is not the device authorized for the current run. Do not tag the release until human acceptance is signed off. Bank synchronization and external financial-provider connections are not part of either historical mode.
