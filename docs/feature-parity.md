# Feature-capability review — v0.4.0

Reviewed 2026-09-04 against public YNAB feature and help material. This is a capability benchmark, not a claim of visual or brand equivalence. Budget App uses original navigation, terminology, and presentation.

Status meanings:

- **IMPLEMENTED** — workflow works against the v0.2 financial/API foundation or is a complete local calculation.
- **PARTIALLY IMPLEMENTED** — foundation or UI exists, but the complete production workflow does not.
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
| Move money and recent moves | PARTIALLY IMPLEMENTED | Auditable native/API moves are implemented; a dedicated recent-moves browser remains future work. |
| Future-month assignments | IMPLEMENTED | Month-addressed ledger and summaries. |
| Underfunded/overspent state | IMPLEMENTED | Native filtered views and attention surfaces. |
| Category notes, icons, customization | PARTIALLY IMPLEMENTED | Icons and note presentation exist; full live editing/reordering is future work. |
| Hidden/inactive categories | PARTIALLY IMPLEMENTED | Archived backend state exists; richer native management remains. |
| Focused/custom views | PARTIALLY IMPLEMENTED | All, Underfunded, Overspent, and Pinned demo views; persistence remains future. |
| Category templates/presets | FUTURE | No template engine yet. |

## Targets and funding

| Capability | Status | Budget App position |
|---|---|---|
| Monthly contribution/spending target | IMPLEMENTED | Generalized target model with amount, minimum, priority, date, and recurrence. |
| Refill/up-to behavior | PARTIALLY IMPLEMENTED | Can be represented in planning UI; explicit persisted behavior needs extension. |
| Weekly/yearly/custom recurrence | PARTIALLY IMPLEMENTED | Recurrence months exists for targets; weekly/custom cadence is not complete. |
| Target by date and savings balance | IMPLEMENTED | Forecast calculations and progress UI. |
| Debt payoff target | PARTIALLY IMPLEMENTED | Native local payoff simulator; dedicated persisted payoff target is future. |
| Snooze/skip target | FUTURE | Not represented in production model. |
| Smart Funding preview | IMPLEMENTED | Shared Before/Proposed/After native workflow and optimistic live batch commit. |
| Funding recommendations | IMPLEMENTED | Target-based deterministic proposals run against the current authoritative month state. |

## Transactions and payees

| Capability | Status | Budget App position |
|---|---|---|
| Manual inflow/outflow | IMPLEMENTED | Live API and fast native entry. |
| Account transfer | IMPLEMENTED | Balanced linked transfer preserves total cash. |
| Credit-card purchase/payment/refund | IMPLEMENTED | Funded reserve accounting, attribution, payments, and reversals. |
| Split transaction | IMPLEMENTED | API model and native multi-category entry. |
| Payee, memo, date, cleared state | IMPLEMENTED | Persisted transaction fields. |
| Reconciliation | IMPLEMENTED | Explicit adjustment only; native comparison preview. |
| Search and filters | IMPLEMENTED | Native transaction search/filter plus server-derived Insights dimensions. Server pagination remains future scale work. |
| Flags/tags | IMPLEMENTED | Persisted production metadata and shared editor. |
| Receipt/photo/file attachment | PARTIALLY IMPLEMENTED | Attachment metadata persists; encrypted binary storage/upload remains future work. |
| Edit and delete/void | IMPLEMENTED | Production edit/delete with immutable before/after/delete audit history. A dedicated void UX remains future work. |
| Duplicate detection | FUTURE | Required before imports; no import pipeline in v0.4.0. |
| Recurring transactions | IMPLEMENTED | Scheduled transaction planning/forecast API. Materialization UI remains limited. |
| Remembered payees, rename, merge | FUTURE | No first-class payee table yet. |
| Local category suggestion | FUTURE | Planned deterministic “2 of last 3” suggestion; never silent mutation. |
| Calculator keypad | FUTURE | Decimal keyboard works; arithmetic expression keypad is not implemented. |

## Accounts, cards, and debt

| Capability | Status | Budget App position |
|---|---|---|
| Checking, savings, cash | IMPLEMENTED | Clearly grouped on-budget cash. |
| Credit card | IMPLEMENTED | Card balance, payment reserve, funded and unfunded spending exposed. |
| Loan/mortgage/tracking asset/liability | PARTIALLY IMPLEMENTED | Native demo and local calculations; production metadata needs dedicated schema. |
| Closed accounts | IMPLEMENTED | Backend and live client state. |
| Net-worth-only tracking distinction | PARTIALLY IMPLEMENTED | `is_on_budget` foundation exists; richer live account classification remains. |
| Payoff simulator | FUTURE | The former demo-only surface was removed rather than presented as production functionality. |
| Card reserve animation | FUTURE | State explanation is present; Reduce Motion-aware animation remains polish work. |

## Insights and forecast

| Capability | Status | Budget App position |
|---|---|---|
| Spending by category/group | IMPLEMENTED | Server-derived accessible chart with filters and contributing transaction IDs. |
| Spending trends and averages | IMPLEMENTED | Shared rolling/calendar/custom range computation over authoritative transactions. |
| Income vs. spending | IMPLEMENTED | Transfer-safe server aggregation with drill-through and edit refresh. |
| Net worth | FUTURE | Requires a production aggregation endpoint and shared UI. |
| Savings/goal progress | IMPLEMENTED | Target progress and forecast foundation, native goal list/detail. |
| Debt progress | PARTIALLY IMPLEMENTED | Payoff estimate exists; persisted interest/principal history is future. |
| Household insights | INTENTIONALLY DIFFERENT | Adds allowance usage, requests, member activity, and permission-aware views. |
| 30/60/90-day, 6-month, 1-year forecast | IMPLEMENTED | Existing forecast API plus clearly labeled projected native UI. |
| Monthly planned cost | FUTURE | The former seeded summary was removed pending a production-backed calculation. |

## Household, privacy, and platform

| Capability | Status | Budget App position |
|---|---|---|
| Household sharing | IMPLEMENTED | Self-hosted household membership. |
| Spouse authority | IMPLEMENTED | Capability bundles or explicit grants. |
| Delegated child budgets | INTENTIONALLY DIFFERENT | Resource visibility plus independently pre-funded, bounded monetary authority go beyond broad shared-budget roles. |
| Requests and partial approvals | IMPLEMENTED | Append-only action history and single balanced approval allocation. |
| Recurring allowances with splits | IMPLEMENTED | Weekly/monthly, rollover/use-it-or-lose-it, explicit issuance. |
| Hide Amounts | FUTURE | The former demo-only toggle was removed pending persistent shared preference support. |
| Export | IMPLEMENTED | Scoped, formula-safe CSV and audit JSON. |
| Offline behavior | PARTIALLY IMPLEMENTED | Deterministic on-device demo works offline; live mutation queue/sync is future. |
| Widgets | FUTURE | Not part of v0.4.0. |
| Accessibility | PARTIALLY IMPLEMENTED | Dynamic Type/native controls, semantic grouping, non-color status labels, VoiceOver labels, chart summaries; formal assistive-technology audit remains. |
| Light/Dark Mode | IMPLEMENTED | System-native appearance verified in Simulator. |
| Bank import/sync | FUTURE | Explicitly blocked; see `bank-sync-readiness.md`. |
| Subscription/SaaS dependency | INTENTIONALLY DIFFERENT | Self-host on a home server, local machine, or chosen website; no required subscription. |

## Where Budget App exceeds the benchmark for household use

- Category- and account-scoped visibility instead of all-or-nothing shared-plan access.
- Independently granted capabilities for balances, reports, transactions, planning, reconciliation, approvals, exports, and allowances.
- Child/teen presentation that removes unrelated income, debt, accounts, and net worth rather than merely disabling edits.
- First-class requests with partial approval, action history, source redaction, and concurrency safeguards.
- Recurring allowance splits with rollover policies and delegated destinations.
- Self-hosted storage and audit export without a mandatory subscription.

## Remaining before bank sync

First-class payees, robust transaction edit/void semantics, duplicate matching, imported-transaction approval, offline conflict resolution, encrypted provider token storage, webhook isolation, retention policy, and formal security review remain prerequisites. No parity claim is made for direct import, Apple Card import, widgets, or production attachment storage.

## Public benchmark sources

- [YNAB Features](https://www.ynab.com/features)
- [YNAB Guides](https://www.ynab.com/guides)
- [YNAB What's New](https://www.ynab.com/whats-new)
- [YNAB Help Center](https://support.ynab.com/)
