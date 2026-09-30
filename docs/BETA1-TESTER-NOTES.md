# Budget App Beta 1 tester notes

## Beta description

ClearPocket Budget is a privacy-first budgeting app designed around exact, category-based money
planning. This closed beta defaults to a private, authoritative budget on the iPhone and needs no
server or sign-in. It also supports connecting to an existing Budget Server for personal and shared
budgets, accounts, category assignments, posted and scheduled transactions,
reconciliation, reports, debt payoff projections and permission-scoped household access.

This is an early beta. Use a disposable test household rather than irreplaceable financial data.
Automatic bank connections and the complete import workflow are not part of this build.

## What to test

1. Launch offline and confirm the production workspace opens directly in **On This iPhone** mode.
2. Create a checking account with a starting balance, category group and category.
3. Assign money and enter a categorized expense. Confirm Plan, Activity and account values agree.
4. Clear and reconcile the expense. Confirm a reconciled transaction cannot be cleared again.
5. Schedule a future transaction, inspect Forecast, then use Enter Now once.
6. Explore Home, Spending Breakdown, reports and Debt payoff projections.
7. Force-quit and reopen the app; confirm the local budget persists while still offline.
8. Try light/dark appearance, larger text and Hide Amounts where useful.
9. From Profile & Settings, choose **Share Beta Feedback**. Describe what you were doing, what
   happened and what you expected. The template includes version and connection state but no
   balances or transaction data.

Please report crashes, repeated alerts, incorrect amounts, missing data, authorization/privacy
issues, confusing dead ends and controls that cannot be reached or edited. Screenshots are useful,
but review them first so they do not reveal personal financial information.

## Known Beta 1 boundaries

- On-device personal mode is persistent and requires no server. Deleting the app also deletes data
  stored only on that phone, so use disposable beta data until backup/restore UI is accepted.
- Training/example data is temporary and deliberately separate from the real local budget.
- Automatic local-to-server migration is not included yet; connecting to a server keeps the local
  copy but does not upload it.
- Bank connectivity is not included.
- Import staging exists as engineering groundwork but is not an approved end-user Beta workflow.
- This build is for closed testing, not production financial recordkeeping.

## App Store Connect fields still requiring owner input

- Feedback email
- Support URL
- Privacy-policy URL
- Beta review contact information
- Test account or server instructions for App Review, if requested
