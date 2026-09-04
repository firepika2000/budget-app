# Product brief

## Working idea

A zero-based budgeting app inspired by envelope budgeting, sold without a recurring subscription and deployable on a laptop, home server, or internet-facing host. A native iPhone client connects to the owner's chosen server. A desktop-friendly web administration interface will follow the API.

This project must use its own name, visual identity, copy, and interaction design; “similar to YNAB” describes the budgeting method, not a UI to clone.

## Product principles

1. **Every dollar has a job.** Income is assigned to categories before spending.
2. **Privacy is deny-by-default.** Household membership never implies access to every budget.
3. **The server is authoritative.** Hidden data is filtered before it leaves the server; client-side hiding is insufficient.
4. **Deployment is portable.** The same application should run locally, on a home server, or on a hosted server.
5. **No required cloud dependency.** Core budgeting continues to work without a vendor-operated service.
6. **Ownership is understandable.** Backups, restores, exports, updates, and remote-access risks are visible to the owner.

## Household and privacy model

A household has one owner and invited members. Members may be adults or children. The owner creates one or more budgets and grants each member access per budget.

| Permission | See budget/categories/transactions | Add transactions | Edit plan | Change sharing |
| --- | --- | --- | --- | --- |
| View | Yes | No | No | No |
| Contribute | Yes | Yes | No | No |
| Manage | Yes | Yes | Yes | No* |
| Owner | Yes, all budgets | Yes | Yes | Yes |

\* Initial policy: only the household owner changes sharing. This can be relaxed later if user research supports delegated administrators.

If a member lacks a grant, list endpoints omit the budget and direct lookups return the same `404` shape as an unknown ID. Transactions, payees, account balances, category totals, search results, notifications, exports, and audit events must all inherit the budget boundary.

## MVP

- Create a household and owner account.
- Create budgets, accounts, categories, monthly assignments, and transactions.
- Show assigned, activity, and available amounts per category.
- Invite a spouse or child and grant View, Contribute, or Manage access to selected budgets.
- Ensure members cannot discover unshared budgets or their derived data.
- Manually enter and reconcile transactions.
- Export a budget and create/restore an encrypted backup.
- Run through a documented local or home-server installation.

## Explicitly after MVP

- Direct bank synchronization (it adds vendor cost, regional limitations, and credentials/compliance work).
- Automatic cross-device discovery of a home server.
- Receipt scanning, investment tracking, debt payoff optimization, and shared savings goals.
- App Store distribution and a hosted commercial service.

## Open product decisions

- One-time purchase, paid major upgrades, or open-core licensing.
- Whether spouse accounts are normally peers or selectively restricted by default.
- Minimum supported iOS and macOS/Windows/Linux administration experience.
- Remote access recommendation: VPN-first versus a built-in secure relay.

