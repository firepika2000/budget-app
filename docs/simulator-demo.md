# v0.3.0 Simulator demo

The Debug build is self-contained and opens a deterministic fictional household immediately. No backend, network, credentials, or bank connection is required for the product-experience review.

## Quick start in Xcode

1. Open `ios/BudgetApp.xcodeproj`.
2. Select the shared **BudgetApp** scheme.
3. Choose any installed iPhone running iOS 17 or later; a Pro-size device is recommended.
4. Press Run.
5. The app opens on Home as Rey in **The Soto Household**.

To exercise the real self-hosted client instead, edit the scheme’s Run arguments and add `--live`. Then start the backend from `server/` with `docker compose up --build`, connect to the displayed local URL, and authenticate normally.

## Demo personas

- **Rey** — owner/admin; full financial and household visibility.
- **Jordan** — full-access partner.
- **Alex** — delegated teenager; only Alex Allowance, Alex Savings, own activity, requests, and allowance.
- **Mia** — delegated child; only Mia Allowance, Mia Bike Goal, own activity, requests, and allowance.

Tap the initial avatar at the upper left to switch persona. Use **Reset Demo Household** in Household to restore the deterministic fixture after trying transactions, approvals, moves, or allowances.

## Representative workflows

- Home → **Make a plan**, or Plan → **Smart Fund**, to inspect a non-mutating Before/Proposed/After preview.
- Plan → **Move** to preview $50 from Dining Out to Fuel.
- Home → Alex’s request to approve $20 of $35 with source/destination preview.
- Avatar → Recurring Allowances → Issue Due Allowance.
- Plan → CNC Machine to inspect the $2,000 goal.
- Insights → Debt Progress and adjust extra payment to $100.
- Insights → Spending or Income vs. Spending for six-month history.
- Avatar → Alex to verify restricted information disappears.
- Avatar → Hide Amounts to mask sensitive values across the app.
- Activity → + for manual or split transaction and receipt/photo/file selection.
- Accounts → Reconcile for a non-mutating comparison.
- Insights → Cash Outlook and choose 30/60/90 days, 6 months, or 1 year.

## Deterministic screenshot routes

Debug-only launch arguments support repeatable review automation:

`--demo-screen=home|plan|activity|accounts|insights|category|transaction|credit|goal|household|child|approval|forecast`

These routes are not compiled into Release behavior because the demo selection is gated by `#if DEBUG` in `RootView`.

## Screenshots

Full-screen captures from an installed iPhone 15 Pro Max (iOS 17.5) are in `docs/screenshots/v0.3.0/`. They include Home, Plan, Category Detail, Transaction Entry, Accounts, Credit Card, Insights, Goal Detail, Household, Child Persona, Request Approval, Forecast, and Dark Mode Home.

