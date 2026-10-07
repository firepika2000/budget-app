# Feature-capability review — current development

Reconciled 2026-10-07 against the current production implementation. This is a capability benchmark, not a claim of visual or brand equivalence. Budget App uses original navigation, terminology, and presentation.

Status meanings:

- **IMPLEMENTED** — workflow works against the v0.2 financial/API foundation or is a complete local calculation.
- **PARTIALLY IMPLEMENTED** — a useful production slice exists, but the broader benchmark remains incomplete.
- **FUTURE** — intentionally deferred.
- **INTENTIONALLY DIFFERENT** — Budget App chooses a different model.
- **NOT APPLICABLE** — excluded from this product.

## Plan and categories

| Capability | Status | Budget App position |
|---|---|---|
| Available to assign | IMPLEMENTED | Derived only from on-budget cash and actual allocations. |
| Category groups and categories | IMPLEMENTED | API, desktop, live iOS, and richer demo UI. |
| Monthly allocation and rollover | IMPLEMENTED | Balanced append-only allocation ledger. |
| Move money and recent moves | IMPLEMENTED | Auditable native/API moves are implemented with a dedicated, permission-filtered Plan history browser covering assignments, moves, Smart Funding, requests, and allowances. |
| Future-month assignments | IMPLEMENTED | Month-addressed ledger and summaries. |
| Underfunded/overspent state | IMPLEMENTED | Native filtered views and attention surfaces. |
| Category notes, icons, customization | IMPLEMENTED | Live and Local Device categories persist editable SF Symbol icons and notes; native management screens drag-reorder active groups and categories through atomic authoritative operations. |
| Hidden/inactive categories | IMPLEMENTED | The production category manager lists active and hidden categories, supports search, preserves history, and lets authorized users hide or restore categories. |
| Focused/custom views | IMPLEMENTED | All, Favorites, Underfunded, Overspent, Funded, and Available views run in the shared production Plan and remember the selected view per user and budget. |
| Category templates/presets | IMPLEMENTED | New budgets default to an editable zero-money starter Plan across server and on-device authorities; creation can explicitly opt out. |

## Targets and funding

| Capability | Status | Budget App position |
|---|---|---|
| Monthly contribution/spending target | IMPLEMENTED | Generalized target model with amount, minimum, priority, date, and recurrence. |
| Refill/up-to behavior | IMPLEMENTED | Persisted Refill Balance targets recommend the exact gap after rollover and current-month spending without moving money automatically. |
| Weekly/yearly/custom recurrence | IMPLEMENTED | Weekly spending counts the anchored weekday's real four/five calendar occurrences; recurring expenses provide monthly, quarterly, six-month, yearly, and custom month cadences with due-date contribution guidance. |
| Target by date and savings balance | IMPLEMENTED | Forecast calculations and progress UI. |
| Debt payoff target | PARTIALLY IMPLEMENTED | Native local payoff simulator; dedicated persisted payoff target is future. |
| Snooze/skip target | IMPLEMENTED | Month-scoped, money-neutral target snooze/resume persists across Live and on-device providers without changing the global target rule. |
| Smart Funding preview | IMPLEMENTED | Shared Before/Proposed/After native workflow and optimistic live batch commit. |
| Funding recommendations | IMPLEMENTED | Target-based deterministic proposals run against the current authoritative month state. |

## Transactions and payees

| Capability | Status | Budget App position |
|---|---|---|
| Manual inflow/outflow | IMPLEMENTED | Live API and fast native entry. |
| Refunds and reimbursements | IMPLEMENTED | Category detail opens the shared transaction editor preconfigured for an exact categorized inflow; the same canonical posting, card-reserve, reporting, offline-create, and permission paths remain in use. |
| Account transfer | IMPLEMENTED | Balanced linked transfer preserves total cash. |
| Credit-card purchase/payment/refund | IMPLEMENTED | Funded reserve accounting, attribution, payments, and reversals. |
| Split transaction | IMPLEMENTED | API model and native multi-category entry. |
| Payee, memo, date, cleared state | IMPLEMENTED | Persisted transaction fields. |
| Reconciliation | IMPLEMENTED | Explicit adjustment only; native comparison preview. |
| Search and filters | IMPLEMENTED | Native transaction search/filter/sort uses bounded cursor-paginated server queries plus server-derived Insights dimensions. |
| Flags/tags | IMPLEMENTED | Persisted production metadata and shared editor. |
| Receipt/photo/file attachment | IMPLEMENTED | Camera, Photos, and Files share one validated application-service path; local content is encrypted at rest with a Keychain-protected key. |
| Edit and delete/void | IMPLEMENTED | Production edit, guarded attachment detach, void/reversal, and immutable before/after/delete audit history. |
| Duplicate detection | IMPLEMENTED | Statement staging identifies duplicate candidates before explicit approval; imports remain non-mutating until reviewed. |
| Recurring transactions | IMPLEMENTED | Active/paused schedule management, forecast-only occurrences, and canonical Enter Now realization share the production editor. |
| Remembered payees, rename, merge | IMPLEMENTED | First-class searchable payees support aliases, defaults, archive, rename, and merge with bounded server-authoritative results. |
| Local category suggestion | IMPLEMENTED | When no explicit payee default exists, transaction entry offers an opt-in category suggestion only after the same visible category appears in at least two of the payee's last three eligible posted purchases. |
| Calculator keypad | IMPLEMENTED | Shared exact-money fields accept parentheses and +, −, ×, ÷ expressions from a native keyboard toolbar; malformed, fractional-minor-unit, divide-by-zero, and overflow results are rejected. |

## Accounts, cards, and debt

| Capability | Status | Budget App position |
|---|---|---|
| Checking, savings, cash | IMPLEMENTED | Clearly grouped on-budget cash. |
| Credit card | IMPLEMENTED | Card balance, payment reserve, funded and unfunded spending exposed. |
| Loan/mortgage/tracking asset/liability | IMPLEMENTED | Live and local creation support first-class loan, mortgage, and tracking types; mortgage/loan debt terms, cost, and payoff projections share exact production semantics. |
| Closed accounts | IMPLEMENTED | Owner-managed close/reopen lifecycle, preserved history and balances, separate open/closed presentation, and transaction-entry protections across Live, local, and demo authorities. |
| Net-worth-only tracking distinction | IMPLEMENTED | First-class Asset and Other Tracking types remain outside the Plan while contributing to permission-filtered net worth. |
| Payoff simulator | IMPLEMENTED | Production avalanche, snowball, rollover, and custom-extra scenarios use exact shared projections and authoritative debt terms without mutating the budget. |
| Card reserve animation | IMPLEMENTED | Exact reserve values use a subtle native numeric transition in Plan and card registers, disabled automatically when Reduce Motion is enabled. |

## Insights and forecast

| Capability | Status | Budget App position |
|---|---|---|
| Spending by category/group | IMPLEMENTED | Server-derived accessible chart with filters and contributing transaction IDs. |
| Spending trends and averages | IMPLEMENTED | Shared rolling/calendar/custom range computation over authoritative transactions. |
| Income vs. spending | IMPLEMENTED | Transfer-safe server aggregation with drill-through and edit refresh. |
| Net worth | IMPLEMENTED | Permission-filtered production aggregation, accessible trend chart, account observations, filters, and drill-through. |
| Savings/goal progress | IMPLEMENTED | Target progress and forecast foundation, native goal list/detail. |
| Debt progress | IMPLEMENTED | Authoritative monthly debt observations show ending debt, net debt change, and explicitly classified recorded interest, with account drill-through and payoff projections kept separately labelled. |
| Household insights | INTENTIONALLY DIFFERENT | Adds allowance usage, requests, member activity, and permission-aware views. |
| 30/60/90-day, 6-month, 1-year forecast | IMPLEMENTED | Existing forecast API plus clearly labeled projected native UI. |
| Monthly planned cost | IMPLEMENTED | Exact production-backed sum of active, non-snoozed target recommendations with explicit scope and overflow handling. |

## Household, privacy, and platform

| Capability | Status | Budget App position |
|---|---|---|
| Household sharing | IMPLEMENTED | Self-hosted household membership. |
| Spouse authority | IMPLEMENTED | Capability bundles or explicit grants. |
| Delegated child budgets | INTENTIONALLY DIFFERENT | Resource visibility plus independently pre-funded, bounded monetary authority go beyond broad shared-budget roles. |
| Requests and partial approvals | IMPLEMENTED | Append-only action history and single balanced approval allocation. |
| Recurring allowances with splits | IMPLEMENTED | Weekly/monthly, rollover/use-it-or-lose-it, explicit issuance. |
| Hide Amounts | IMPLEMENTED | Per-user/per-budget device preference masks values, charts, app-switcher content, and accessibility values without changing shared data. |
| Export | IMPLEMENTED | Scoped, formula-safe CSV and audit JSON. |
| Encrypted backup and restore | IMPLEMENTED | Local Device budgets support verified, versioned encrypted backup and new-destination restore through Files and Dropbox. Dropbox uses immutable generations rather than live database sync; shipping it requires ClearPocket's registered public OAuth app key. |
| Offline behavior | PARTIALLY IMPLEMENTED | Authoritative on-device personal mode works fully offline with durable exact-money state and encrypted attachments. Server mode has a protected last-known workspace cache plus idempotent queued transaction creation and replay. Broader mutation outbox coverage and conflict resolution remain future work. |
| Widgets | FUTURE | Not part of v0.4.0. |
| Accessibility | PARTIALLY IMPLEMENTED | Dynamic Type/native controls, semantic grouping, non-color status labels, VoiceOver labels, chart summaries; formal assistive-technology audit remains. |
| Light/Dark Mode | IMPLEMENTED | System-native appearance verified in Simulator. |
| Bank import/sync | PARTIALLY IMPLEMENTED | Reviewed CSV/OFX/QFX/QBO and text-based statement import is implemented with mapping, matching, approval, history, and undo; direct bank connectivity remains gated by `bank-sync-readiness.md`. |
| Subscription/SaaS dependency | INTENTIONALLY DIFFERENT | Self-host on a home server, local machine, or chosen website; no required subscription. |

## Where Budget App exceeds the benchmark for household use

- Category- and account-scoped visibility instead of all-or-nothing shared-plan access.
- Independently granted capabilities for balances, reports, transactions, planning, reconciliation, approvals, exports, and allowances.
- Child/teen presentation that removes unrelated income, debt, accounts, and net worth rather than merely disabling edits.
- First-class requests with partial approval, action history, source redaction, and concurrency safeguards.
- Recurring allowance splits with rollover policies and delegated destinations.
- Self-hosted storage and audit export without a mandatory subscription.

## Remaining before bank sync

Server-backed offline conflict resolution, encrypted future bank-provider token storage, webhook isolation,
provider retention policy, and formal security review remain prerequisites. No parity claim is made for
direct bank connectivity, Apple Card automation, or widgets. Manual statement import and encrypted
production attachment storage are already implemented and must not be treated as missing foundations.

## Public benchmark sources

- [YNAB Features](https://www.ynab.com/features)
- [YNAB Guides](https://www.ynab.com/guides)
- [YNAB What's New](https://www.ynab.com/whats-new)
- [YNAB Help Center](https://support.ynab.com/)
