# Insights architecture

Insights is a query over authoritative transactions, not a second financial ledger. User-facing date ranges are inclusive at both ends and support rolling 30, 60, and 90 days; three and six months; year to date; one year; and custom dates.

The shared SwiftUI Insights view and `BudgetWorkspaceStore` build the same report query for either runtime. Authenticated mode sends it to the server analytics repository, where access-scoped transactions are filtered and aggregated. Debug demo mode evaluates the query against its deterministic transaction repository. Both return the same `APISpendingReport` and `APIIncomeSpendingReport` contracts.

Supported dimensions are account, category, category group, payee, member, transaction type, cleared state, and inclusion of tracking accounts. Transfers are excluded from income and spending. Category refunds reduce category spending rather than becoming income.

Every aggregate includes contributing transaction identifiers. Selecting an aggregate opens the shared transaction list and editor. A successful mutation reloads the repository snapshot and recalculates reports, so changed dates, amounts, accounts, categories, payees, splits, tags, flags, and attachment metadata cannot leave a stale chart behind.

The server remains the production source of truth. Demo calculations exist to make simulator review deterministic, not to replace production analytics.
