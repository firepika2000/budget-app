# Budget App Product Specification

**Document:** `docs/PRODUCT-SPECIFICATION.md`\
**Status:** Authoritative Product Definition\
**Specification Version:** 1.0-draft\
**Date:** 2026-09-08\
**Product Stage:** Pre-1.0 / v0.4 stabilization and architecture
alignment

------------------------------------------------------------------------

## 0. Purpose and Authority

This document defines what Budget App is supposed to be, how it behaves,
what financial rules it must preserve, how users interact with it, and
how its different data-hosting modes relate to one canonical
application.

It is the product-level source of truth for future architecture,
implementation, acceptance testing, and roadmap decisions.

Where current code, the Deterministic Demo, the Live Server, an older
implementation path, or an earlier roadmap conflicts with this
specification, the conflict must be identified explicitly. Existing
behavior does not become correct merely because it already exists.

The product has two complementary authorities:

1.  **The canonical product specification** defines intended user
    behavior, navigation, terminology, permissions, workflows, and
    capabilities.
2.  **The authoritative accounting engine and financial invariants**
    define financial truth. A Demo, UI, repository, import provider, AI
    feature, or synchronization mechanism may not invent alternate
    accounting semantics.

The Deterministic Demo is the reference product experience and sample
dataset, but known Demo accounting defects are not canonical behavior.
The Demo must converge on this specification rather than preserve
incorrect fixture behavior.

------------------------------------------------------------------------

# 1. Product Definition

Budget App is a **local-first, user-owned household financial operating
system** centered on allocation budgeting.

It is not primarily an expense tracker. It helps a person or household
decide what existing money needs to do, record what actually happens,
coordinate shared financial authority, understand historical behavior,
forecast known future obligations, and explore hypothetical financial
decisions without confusing those concepts.

The product should provide the familiarity and functional completeness
expected from a mature allocation-budgeting application while remaining
an original product with its own terminology, interface, architecture,
and capabilities.

Budget App is designed around five ideas:

-   **Reality first.** Money must exist before it becomes spendable.
-   **Every real budget dollar has one financial truth.** Moving,
    delegating, reserving, or synchronizing money must never duplicate
    it.
-   **Households are collaborative.** Multiple members can have
    different visibility and authority while operating against one
    authoritative financial state.
-   **Users own their data and deployment.** The same application can
    operate entirely on one device or against a server controlled by the
    household.
-   **Planning, forecasting, scenarios, automation, imports, and AI
    never replace the deterministic accounting engine.**

## 1.1 Product positioning

Budget App should ultimately be capable of serving:

-   a single person using only an iPhone;
-   a couple jointly managing shared finances;
-   a family with children or other delegated household members;
-   a power user operating a home server or NAS;
-   a household running Budget Server on a remote Mac, Windows, or Linux
    system;
-   users who want encrypted user-owned cloud backup storage;
-   users who later want imports or bank connectivity without
    surrendering the core local-first model.

## 1.2 Non-goals

Budget App is not:

-   a bank;
-   a payment processor;
-   an accounting system that allows anticipated income to become
    current spendable money;
-   a cloud SaaS service that requires a vendor-hosted account to
    function;
-   an AI-controlled ledger;
-   a set of separate Demo, Live, Personal, and Server applications;
-   a system where hiding a control in the UI substitutes for
    server-side authorization;
-   a file-sync database that permits multiple devices to edit the same
    database file concurrently;
-   a reason for ordinary household users to learn PostgreSQL, Docker,
    Python, migrations, environment variables, or command-line
    administration.

Bank connectivity is intentionally deferred until the core product,
self-hosting, backup, synchronization, permissions, and accounting
semantics are stable.

------------------------------------------------------------------------

# 2. Product Principles

## 2.1 Existing money is the basis of the plan

A budget plans money the household actually controls. Scheduled
paychecks, expected bonuses, hypothetical income, and scenario income
may influence forecasts, but they are not spendable and do not increase
Unassigned until they become actual transactions.

**Canonical rule:** You can plan future time, but you cannot spend
future money.

## 2.2 Accounts describe location; categories describe purpose

An account answers **where is the money or debt?**

A category answers **what is the budget money for?**

Moving money between accounts does not inherently change its category
purpose. Assigning money to a category does not inherently move it
between bank accounts.

## 2.3 Exact money

Authoritative monetary amounts use integer minor units or an
equivalently exact decimal representation. Binary floating point is not
authoritative for money.

Charts may derive floating-point geometry from exact values, but chart
geometry is never financial truth.

## 2.4 Conservation

Allocation operations may move financial authority but may not create
cash.

Transfers between accounts conserve value absent an explicitly recorded
fee, gain, loss, or adjustment.

Delegation transfers authority over existing household money; it never
creates a second copy of that money.

## 2.5 One application

Home, Plan, Activity, Accounts, Insights, Profile & Settings, editors,
empty states, error states, and core workflows are one canonical
product.

Data source or deployment mode may change authentication, network state,
synchronization, persistence, server administration, or capability
availability. It may not create a separate application experience.

## 2.6 Explainability

Users should be able to determine why a balance, recommendation,
forecast, chart, or warning exists.

Budget App should prefer transparent deterministic metrics over opaque
financial-health scores.

## 2.7 Auditability

Material financial mutations are attributable to an authenticated actor
where identity exists.

Corrections are allowed. History is not silently rewritten.

## 2.8 Privacy by construction

Restricted information must be removed from the member's effective
dataset, not merely hidden by a view.

Totals, reports, search, notifications, attachments, forecasts, and
activity feeds must not leak inaccessible resources.

## 2.9 User ownership and portability

A household must be able to back up, restore, migrate, and export its
financial information without dependence on a proprietary hosted
service.

## 2.10 YNAB as a behavioral reference, not a cloning target

YNAB's public guidance and product behavior may be studied as a mature
reference for allocation budgeting, reconciliation, targets, scheduled
transactions, credit-card budgeting, focused planning views, and
reporting.

Budget App must use original product terminology, original UI design,
and its own implementation. Where this specification deliberately
extends beyond the reference model - such as richer household
permissions, audit attribution, interactive analytical drill-down,
deployment choice, self-hosting, and scenarios - the Budget App behavior
in this document is authoritative.

------------------------------------------------------------------------

# 3. Canonical Application Model

## 3.1 One canonical product

Conceptually:

``` text
                    BUDGET APP
                        |
                Canonical Product UI
                        |
               Application Services
                        |
                 Domain / Models
                        |
              Repository Contracts
                        |
        +---------------+---------------+
        |               |               |
        v               v               v
   On-Device       Budget Server    Deterministic
   Repository       Repository       Repository
   Personal Mode    Shared Mode      Sample Data
```

Future import and bank-connectivity components feed proposed/candidate
data into this system. They do not bypass it.

## 3.2 Canonical workspace

Once an active budget has been resolved, the primary application
workspace is:

``` text
Home | Plan | Activity | Accounts | Insights
```

**Profile & Settings** is globally reachable from the active workspace.

A budget is a **workspace/context**, not a page nested beneath a normal
Budgets browser.

## 3.3 Active-budget resolution

After identity and source resolution:

``` text
Accessible budgets = 0
    -> onboarding / create budget / waiting-for-access state

Accessible budgets = 1
    -> open it automatically

Accessible budgets > 1
    -> if a valid last-active budget exists, open it
    -> otherwise show Choose Budget
```

The selected active budget is persisted per user/device.

The budget chooser is an exceptional resolution surface, not a permanent
parent of the workspace.

Budget creation and switching normally live in Profile & Settings.

## 3.4 Household hierarchy

``` text
Installation / Local Repository
└── Household
    ├── Members
    ├── Household-owned Payees
    ├── Household Security / Permissions
    ├── Budget A
    ├── Budget B
    └── Budget C
```

The **Household** is the ownership and security boundary.

Members belong to a household. Budgets live beneath the household. A
member may be granted access to one budget without discovering another.

## 3.5 Product state machine

The exact state machine depends on repository capabilities, but the
conceptual flow is:

``` text
Launch
  -> Repository/source resolution
  -> Repository availability
  -> Identity/authentication when required
  -> Household resolution
  -> Accessible-budget resolution
  -> Active Budget Workspace
```

Personal on-device mode may skip network authentication. Deterministic
sample mode may skip authentication. Those are lifecycle differences,
not different workspace products.

------------------------------------------------------------------------

# 4. Canonical Terminology

Budget App should use one canonical user-facing term for each major
concept.

  Concept                                                  Canonical term
  -------------------------------------------------------- ---------------------------
  Existing on-budget money without a category purpose      **Unassigned**
  Money intentionally allocated to a category              **Assigned**
  Period transactions affecting a category                 **Activity**
  Current spendable/category balance                       **Available**
  Category spending beyond available funding               **Overspent**
  Physical/financial location of money or debt             **Account**
  Intended purpose of budget money                         **Category**
  Expected future transaction definition                   **Scheduled Transaction**
  Planning rule attached to a category/account             **Target**
  Expected future based on known events                    **Forecast**
  Isolated hypothetical future                             **Scenario**
  Verified comparison to institution balance               **Reconciliation**
  Canonical merchant/person/organization on transactions   **Payee**
  Household member with scoped authority                   **Member**

Legacy internal/API/database field names may remain for compatibility
when safe. Product terminology should not force unnecessary schema
churn.

------------------------------------------------------------------------

# 5. Financial Domain Model

## 5.1 Core entities

The canonical domain includes, at minimum:

-   Household
-   Member / Membership
-   Budget
-   Account
-   Category Group
-   Category
-   Monthly Planning Period
-   Assignment
-   Allocation Transfer / Money Move
-   Transaction
-   Transaction Split
-   Account Transfer
-   Payee
-   Payee Alias
-   Credit Card Payment Reserve
-   Reconciliation
-   Reconciliation Adjustment
-   Target
-   Scheduled Transaction
-   Forecast
-   Scenario
-   Financial Request
-   Approval / Request Action
-   Delegated Budget Policy / Authority
-   Allowance Plan
-   Permission / Capability / Resource Grant
-   Audit Event
-   Attachment
-   Backup Metadata
-   Repository / Device / Session identity where applicable.

## 5.2 First-class payees

Payees are household-owned entities rather than arbitrary strings only.

A payee may include:

-   canonical display name;
-   aliases used for import/matching;
-   transaction history;
-   rename history where appropriate;
-   merge support;
-   optional categorization defaults or suggestions;
-   per-budget interpretation when the same payee maps differently in
    different budgets.

Example:

``` text
Payee: Walmart
Aliases:
- WAL-MART #1234
- WM SUPERCENTER 1234
- Walmart Supercenter

Budget A default category: Groceries
Budget B default category: Supplies
```

Payee matching may later assist imports. Matching never overrides user
confirmation or accounting invariants.

------------------------------------------------------------------------

# 6. Accounts

## 6.1 Account classes

Budget App supports two first-class account classes.

### Budget Accounts

These participate directly in the allocation budget.

Typical types:

-   Checking
-   Savings
-   Cash
-   Credit Card

### Tracking Accounts

These contribute to the broader financial picture but do not create
Unassigned or category money.

Typical types:

-   Mortgage
-   Auto Loan
-   Personal Loan
-   Student Loan
-   Investment
-   Property / Real Estate
-   Vehicle / Other Asset
-   Other Liability

Example:

``` text
Checking                     $8,000
Savings                     $12,000
Budget cash                 $20,000

Home                       $400,000
Mortgage                  -$280,000
401(k)                      $90,000
Vehicle                     $25,000
Auto loan                  -$10,000
Tracked net assets         $225,000

Net worth                  $245,000
```

Only the \$20,000 of on-budget cash participates in allocation.

## 6.2 Starting balances

Starting balance is a first-class account-creation concept.

The user should be able to create:

``` text
Checking
Current / Starting Balance: $4,500
```

For a positive on-budget cash account, the recognized money becomes
**Unassigned**.

Internally, the engine may represent this through an opening-balance
transaction or equivalent posting, but the user does not need to create
a fake manual transaction after account creation.

The creation UI must clearly communicate the consequence.

Opening balances have the following canonical effects:

-   A positive on-budget cash opening balance increases **Unassigned**.
-   A negative credit-card opening balance creates existing unfunded
    card debt and creates no payment reserve.
-   A Tracking asset opening balance contributes to net worth only.
-   A Tracking liability opening balance contributes to net worth only.

Tracking opening balances never affect Unassigned.

## 6.3 Rich account metadata

The canonical product may support richer metadata such as:

-   APR / interest rate;
-   minimum payment;
-   due date;
-   original balance;
-   term;
-   current principal;
-   payoff estimate;
-   asset value;
-   linked liability;
-   estimated equity.

The canonical Demo may lead implementation here. These concepts should
be promoted into the product model rather than removed solely because a
current Live backend lacks them.

## 6.4 Account lifecycle

Accounts with meaningful financial history are not normally deleted.

``` text
Active -> Closed / Archived
```

Closing should preserve:

-   transactions;
-   reconciliation history;
-   Activity events;
-   reporting history;
-   net-worth history;
-   actor attribution;
-   linked historical schedules and payments.

Budget accounts should generally be at zero before closure or require an
explicit accounting operation explaining the remaining balance/debt.

The app should identify unresolved dependencies such as scheduled
transactions before closure.

An accidental account with no meaningful financial history may be
permanently deleted.

------------------------------------------------------------------------

# 7. Monthly Planning Model

## 7.1 Persistent planning periods

Each month is a real planning period with its own assignments and
activity.

Navigating from September to October does not transform September into
October. Historical months remain queryable records.

A month contains, conceptually:

-   opening category balances;
-   rollover effects;
-   assignments;
-   category Activity;
-   ending Available values;
-   applicable overspending state.

## 7.2 Future planning

Users may navigate to future planning periods.

Existing real money may be assigned in a future month.

Expected future income may be shown in Forecast and may inform
target/plan guidance, but it cannot become Unassigned until it becomes
an actual transaction.

## 7.3 Cash overspending rollover policy

Cash overspending treatment is a **per-budget user setting**.

### Policy A - Absorb into next month

An unresolved cash deficit is absorbed by the next planning period:

``` text
September Groceries Available: -$100

October:
Groceries opening deficit: $0
Unassigned impact: -$100
```

### Policy B - Carry category deficit

The deficit remains attached to the category:

``` text
September Groceries Available: -$100

October:
Groceries opening Available: -$100
Unassigned does not separately lose another $100
```

**Invariant:** unresolved cash overspending is represented exactly once.
The system may never both carry the negative category balance and
independently reduce Unassigned for the same deficit.

The recommended default is **Absorb into next month**, but the household
chooses per budget.

## 7.4 Rollover policy effective history

Changing a budget's cash-overspending rollover policy is prospective.
Historical planning periods retain the policy that applied when each
period crossed its month boundary. Changing the current setting must not
silently reinterpret historical Unassigned or category balances.

The eventual policy representation must therefore be effective-period
or history aware rather than treating one current enum as permission to
rewrite prior planning periods.

Credit overspending follows credit-card debt/reserve semantics and is
not treated identically to cash overspending.

------------------------------------------------------------------------

# 8. Assignments, Moves, and Unassigned

## 8.1 Unassigned

**Unassigned** is real on-budget money that has not yet been assigned a
category purpose.

It is not projected income, net worth, tracking-account value, available
credit, or scenario money.

Unassigned is the budget's net unallocated position:

-   If Unassigned is positive, real existing on-budget money remains
    available to assign.
-   If Unassigned is zero, all existing allocatable money has purpose.
-   If Unassigned is negative, the budget has an unresolved funding
    deficit that must be corrected.

Negative Unassigned is not future income and does not create cash. It
allows absorbed prior-month cash overspending or a real negative
reconciliation adjustment to expose a funding deficit without violating
financial conservation.

## 8.2 Assignment

Assigning money:

-   decreases Unassigned;
-   increases the category's assigned/available authority;
-   does not move cash between accounts;
-   does not create or destroy household cash.

## 8.3 Moving money

Moving money between categories:

-   reduces the source category;
-   increases the destination category;
-   conserves total allocation;
-   is an auditable financial event;
-   is attributable to the acting member.

------------------------------------------------------------------------

# 9. Transactions, Income, Refunds, and Transfers

## 9.1 Actual transactions

Transactions record financial reality.

An actual transaction may affect:

-   account balance;
-   category Activity;
-   category Available;
-   Unassigned;
-   credit reserve/debt;
-   reports;
-   net worth;
-   Activity timeline.

## 9.2 Income

An uncategorized positive inflow to an on-budget cash account becomes
Unassigned.

## 9.3 Categorized positive inflows

A positive transaction intentionally assigned to a spending category
restores that category.

Example:

``` text
Groceries Assigned             $600
Publix                         -$150
Publix Refund                   +$50

Activity                       -$100
Available                       $500
```

The \$50 does not also become Unassigned.

This supports refunds and reimbursements such as a friend reimbursing a
shared meal.

## 9.4 Reporting treatment

Refunds/reimbursements should not inflate earned-income reporting merely
because money entered an account.

Reporting must distinguish income from reversals/reimbursements where
classification is known.

Allocation destination and reporting meaning are separate concepts. A
positive transaction may restore a category or become Unassigned based
on its allocation/category treatment. Independently, reporting may
classify that transaction as earned income, refund, reimbursement,
opening balance, reconciliation adjustment, transfer/system event, or
another future explicit type.

Categorization alone must not permanently prevent the system from
distinguishing earned income from refunds or reimbursements when the
classification is known.

## 9.5 Account transfers

A transfer between accounts is not income or spending merely because
cash changed location.

Paired transfer legs must conserve value absent an explicit
fee/adjustment.

------------------------------------------------------------------------

# 10. Credit Cards

## 10.1 Canonical model

Credit-card purchases are categorized spending.

Credit-card payments are account transfers, not a second expense.

Funded card spending reserves real budget cash for repayment.

Unfunded card spending becomes debt.

Example:

``` text
Groceries Available before purchase     $600
Visa grocery purchase                   -$150

Groceries Available                      $450
Visa Reserved for Payment                $150
Visa Balance                            -$150
```

Payment:

``` text
Checking                                -$150
Visa                                    +$150
Reserved for Payment                    -$150
```

No second spending event is created.

## 10.2 Unfunded purchase

If only \$20 is funded and an \$80 card purchase occurs:

``` text
Funded portion                           $20
Unfunded portion                         $60
```

Only funded spending may create payment reserve. The remainder becomes
debt.

## 10.3 Refunds

A refund must reverse the appropriate spending-category effect and
release/rebuild the associated payment reserve/debt attribution exactly
once.

## 10.4 Credit-card UI

Credit accounts should explain the state directly, for example:

``` text
Everyday Visa
Balance                           -$1,428.64
Reserved for payment               $1,050.00
Unfunded debt                        $378.64
Minimum payment                       $75.00
Due                                  Sep 18
```

The user should not need to understand internal reserve-event
implementation to understand why cash is or is not available to pay the
card.

------------------------------------------------------------------------

# 11. Reconciliation

Reconciliation verifies that Budget App and the external financial
institution agree as of a specified date.

The app must not silently alter an account merely to make it appear
reconciled.

Canonical flow:

``` text
Enter statement balance/date
        |
Compare cleared records
        |
        +-- Difference = 0 -> reconcile
        |
        +-- Difference != 0
              -> review transactions
              -> or explicitly create adjustment
```

## 11.1 Reconciliation adjustments

A reconciliation adjustment is a real, authorized, auditable
transaction.

If a positive adjustment reveals additional real on-budget cash, that
amount becomes Unassigned.

If a negative adjustment reveals missing on-budget cash, the allocation
system must reflect that loss. Available Unassigned may absorb it when
sufficient; otherwise the budget must clearly show an underfunded state
requiring resolution rather than silently stealing from an arbitrary
category.

## 11.2 Protected history

Reconciled transactions may be corrected, but editing or deleting them
requires an explicit warning and produces audit history.

Reconciliation establishes trust; subsequent edits must not erase the
fact that previously reconciled history changed.

## 11.3 Reconciliation and cash overspending are independent

A reconciliation adjustment changes actual account cash and therefore
the budget's unallocated position. Cash overspending is category Activity
that exceeds funded cash and is resolved according to the applicable
month rollover policy.

The same financial loss must never be represented once as a
reconciliation loss and again as an absorbed category deficit unless two
genuinely separate financial events occurred. Exactly-once
representation remains mandatory.

------------------------------------------------------------------------

# 12. Scheduled Transactions

A Scheduled Transaction is a planning object, not an actual transaction.

Before realization it may influence:

-   Home upcoming obligations;
-   Forecast;
-   target/funding recommendations;
-   insufficient-funding warnings;
-   projected account balances.

It must not change actual:

-   account balances;
-   category Activity;
-   category Available;
-   Unassigned;
-   net worth;
-   earned/spent totals.

## 12.1 Realization

A due date alone does not automatically manufacture an actual
transaction.

A due item may offer:

``` text
[Enter] [Edit Amount] [Skip]
```

When entered, the actual transaction retains lineage to the originating
schedule.

The actual amount may differ from the expected amount.

Recurring schedules advance according to defined cadence rules. Paused
schedules do not contribute active future occurrences but do not erase
historical transactions already created from them.

Future bank imports may be matched to scheduled items. The
imported/confirmed actual transaction is what changes financial reality.

**Canonical rule:** schedules predict; transactions record reality.

------------------------------------------------------------------------

# 13. Targets and Smart Funding

A Target is a planning rule. It does not own money.

Money remains in the allocation ledger/category.

Canonical target concepts include:

-   Monthly Funding
-   Maintain Balance
-   Balance by Date
-   Recurring Expense
-   Debt Payment / minimum funding guidance

Targets may include:

-   amount;
-   cadence;
-   due date;
-   minimum contribution;
-   priority;
-   active/inactive state.

## 13.1 Recommendations

Targets answer questions such as:

-   How much should be assigned this month?
-   Is this category on track?
-   How much remains?
-   What is underfunded?

## 13.2 Smart Funding

Smart Funding may evaluate:

-   overspending;
-   scheduled obligations;
-   target due dates;
-   target priorities;
-   credit-card funding requirements;
-   currently available Unassigned.

It must generate a **preview** before changing allocations.

Example:

``` text
Unassigned: $2,340

Recommended:
Mortgage                  $2,100
Electric                     $120
Emergency Fund               $120
Total                      $2,340

[Review] [Apply]
```

Nothing moves until the user confirms.

If requirements exceed available money, the product must say so rather
than pretend all targets are funded.

AI may later explain or propose funding strategies, but the
deterministic engine computes authoritative consequences.

------------------------------------------------------------------------

# 14. Household, Identity, Permissions, and Delegation

## 14.1 Household security boundary

The Household owns:

-   members;
-   budgets;
-   household payees;
-   household security policy;
-   permission/grant relationships;
-   deployment/server relationship where applicable.

## 14.2 Owner-established subordinate accounts

Subordinate household accounts are established or invited under
owner-controlled policy.

A member only discovers budgets the owner has made accessible.

Within an accessible budget, the member only sees resources enabled for
that member and may only perform actions for which authority has been
granted.

## 14.3 Visibility and authority are separate

Permissions must distinguish:

**Visibility:** Can this member know the resource/information exists?

**Authority:** What may this member do with it?

Example:

``` text
Alex Checking

View balance                 Yes
View transactions            Yes
Create transactions          Yes
Edit own transactions        Yes
Edit all transactions        No
Transfer from account        Yes
Transfer to account          Yes
Reconcile                    No
Modify account settings      No
Close account                No
```

Transfer authority may be directional. The canonical authorization
model may independently express `transfer_in` and `transfer_out`.
Simple/default roles may grant both together, while fine-grained
household policy may grant them independently.

## 14.4 Deny by default

A resource outside a member's visibility scope must not leak through:

-   account lists;
-   Home totals;
-   Activity;
-   Insights;
-   net worth;
-   search;
-   forecasts;
-   category detail;
-   notifications;
-   attachments;
-   API payloads.

UI filtering is not the security boundary. Shared-server authorization
is server-authoritative.

## 14.5 Delegated financial authority

Delegation grants authority over existing household money.

Supported patterns include:

1.  **Fixed allowance** - e.g. \$20 weekly.
2.  **Owner-funded envelope** - owner manually funds delegated
    authority.
3.  **Request/approval** - member requests additional funds; an
    authorized member approves all, part, requests changes, or rejects.

Example allowance:

``` text
$20 every Friday

50% Spending
30% Savings
20% Giving
```

Allowance execution may not create money. The funding source must
possess sufficient authority/funds.

## 14.6 Delegated autonomy

Owners may independently control whether a member can:

-   view delegated categories;
-   spend from them;
-   move money among their own categories;
-   request additional money;
-   create categories;
-   see household Unassigned;
-   see household income;
-   see specified accounts;
-   reconcile;
-   administer budgets or household settings.

Adult partners may share broad authority. Children or other delegated
members may have narrow scopes.

------------------------------------------------------------------------

# 15. Actor Attribution and Audit History

In a multi-user household, every meaningful mutation should record the
authenticated actor.

Examples:

``` text
Publix -$142.18
Groceries • Checking
Added by Dad • 6:42 PM

Moved $75
Dining Out -> Groceries
By Mom • 4:17 PM

Alex requested $40
Requested by Alex • 8:03 AM

Approved $30
By Mom • 8:26 AM
```

## 15.1 Object history

Important objects should expose useful history:

``` text
Transaction History

Sep 11 • Mom
Changed category
Dining Out -> Groceries

Sep 10 • Dad
Changed amount
$138.72 -> $142.18

Sep 10 • Dad
Created transaction
```

System attribution is not an editable user note.

User notes and system audit history are separate concepts.

## 15.2 Audit immutability

Users may correct financial records according to their permissions, but
they may not rewrite the audit trail to pretend the prior event never
happened.

The audit system should record meaningful before/after information while
respecting privacy and retention policy.

------------------------------------------------------------------------

# 16. Activity

Activity is the budget's broader financial timeline, not merely another
transaction register.

Account screens retain account-specific transaction registers.

Activity may include:

-   transactions;
-   account transfers;
-   assignments;
-   category money moves;
-   requests and approvals;
-   reconciliation events;
-   reconciliation adjustments;
-   scheduled-transaction realization;
-   account lifecycle changes;
-   target changes where useful;
-   household/admin events where permitted.

Canonical filters may include:

``` text
All Activity
Transactions
Assignments
Transfers
Requests & Approvals
Reconciliations
Schedules
Account Changes
Household/Admin
```

Activity must respect effective permissions and must not reveal hidden
resources through event descriptions, totals, actor information, or
metadata.

------------------------------------------------------------------------

# 17. Insights and Reporting

Insights is a comprehensive financial-analysis workspace.

A mature allocation-budgeting application's reporting capabilities
establish the minimum behavioral baseline. Budget App extends that
baseline with deeper drill-down, household-aware filtering,
budget-performance analysis, debt analysis, financial-resilience
metrics, and scenario comparison.

## 17.1 Core Insight families

### Overview

-   Income
-   Spending
-   Net cash flow
-   Savings rate
-   Net worth
-   Financial buffer/resilience

### Spending

-   Spending breakdown
-   Spending trends
-   Category/group trends
-   Payee trends
-   Monthly averages
-   transaction drill-down

### Income and Cash Flow

-   Income vs. spending
-   Income sources
-   monthly net cash flow
-   average income
-   average spending

### Net Worth

-   assets;
-   liabilities;
-   net worth;
-   historical change;
-   account contribution;
-   asset/liability breakdown.

### Budget Performance

-   Assigned vs. spent;
-   target performance;
-   category funding history;
-   overspending history;
-   Unassigned history;
-   rollover trends.

### Debt

-   total debt;
-   debt by account;
-   principal reduction;
-   interest paid where known;
-   credit-card debt;
-   payoff progress.

### Financial Resilience

Transparent deterministic metrics may include:

-   cash buffer;
-   essential-expense coverage in days/months;
-   emergency-fund coverage;
-   savings rate;
-   required monthly obligations;
-   expected near-term margin.

Avoid unexplained proprietary composite scores.

## 17.2 Filters

Reports should support appropriate combinations of:

-   date range;
-   account;
-   Budget vs. Tracking account class;
-   category group;
-   category;
-   payee;
-   member/actor where authorized;
-   transaction type;
-   cleared/reconciled state;
-   tags/flags where implemented.

## 17.3 Interactive charts

Charts are interfaces to financial records, not decoration.

The user should have multiple appropriate chart choices, including:

-   donut/pie for part-to-whole composition;
-   bar for category/payee comparisons;
-   stacked bar where composition over periods matters;
-   line/trend for time series;
-   other purpose-built views where they materially improve
    comprehension.

The same filtered dataset should remain authoritative when the
visualization changes.

## 17.4 Drill context

Chart selection should progressively narrow a reusable filter context.

Example:

``` text
Spending
 -> Transportation
 -> Gasoline
 -> Wawa
 -> individual transactions
```

A Gasoline donut slice can be tapped to reveal a new breakdown by payee:

``` text
Gasoline: $486

Wawa       $186
Shell      $142
Costco Gas $104
7-Eleven    $54
```

Tapping Wawa then reveals the transactions that produced \$186.

The same context may switch from donut to bar without losing filters.

Time-oriented charts may drill from a month into
categories/payees/transactions.

Net-worth charts may drill:

``` text
Net Worth -> Liabilities -> Auto Loan -> balance history -> payments
```

A visible breadcrumb/back path should preserve orientation.

## 17.5 Reporting truth

Every displayed aggregate should be traceable to underlying records when
permissions allow.

Charts must never calculate a competing financial truth.

## 17.6 Permissions

If a member cannot see the mortgage, the mortgage must not be inferable
through net-worth totals, charts, percentages, forecast deltas, or
report exports.

## 17.7 Export

Report data should be exportable in useful open formats where
appropriate.

Report export is not the same as a full-fidelity application backup.

------------------------------------------------------------------------

# 18. Forecasting

Forecast represents expected future financial behavior based on known
planning inputs such as Scheduled Transactions and defined recurring
obligations.

Forecast may project:

-   account balances;
-   household cash;
-   known obligations;
-   expected income;
-   credit payments;
-   debt balances where modeled;
-   selected category needs;
-   cash-flow margin.

Forecast does not alter actual balances, Unassigned, Available,
Activity, or net worth.

Forecast should distinguish confidence/source where useful, such as:

-   known scheduled;
-   modeled recurring;
-   user assumption.

Longer horizons should not be presented with the same certainty as
near-term known obligations.

At least a 12-month useful horizon should be supported, with longer
horizons for debt, mortgage, savings, and net-worth modeling where
inputs justify it.

------------------------------------------------------------------------

# 19. Scenarios

Scenario is an isolated hypothetical sandbox.

The conceptual distinction is:

``` text
ACTUAL
What is financially true.

PLAN
How existing real money is assigned.

FORECAST
What is expected from known future events.

SCENARIO
What might happen under hypothetical assumptions.
```

Scenarios may model:

-   vehicle purchase;
-   home purchase;
-   major cash purchase;
-   job/income change;
-   raise;
-   loss of income;
-   recurring-expense change;
-   accelerated debt payoff;
-   financing alternatives;
-   interest-rate/term changes;
-   moving;
-   retirement/savings changes;
-   childcare;
-   vacation/project costs.

Multiple scenarios may be compared to baseline and to each other.

Interactive charts should support baseline-vs-scenario comparisons for:

-   cash;
-   net worth;
-   debt;
-   savings;
-   obligations;
-   payoff dates.

No scenario may contaminate the authoritative ledger.

A user may explicitly convert an appropriate scenario assumption into a
real target, schedule, account, or other plan object, but this requires
a deliberate action.

AI may translate natural language into a **proposed scenario**. The
deterministic scenario engine performs the calculations.

------------------------------------------------------------------------

# 20. Attachments, Receipts, and Documents

Attachments are optional first-class product objects.

Supported attachment use cases include:

-   receipt images;
-   scanned receipts;
-   PDF invoices;
-   warranties;
-   transaction-related documents;
-   loan/account documents where appropriate.

Multiple attachments may be associated with a supported object.

The self-hosted/shared repository stores the actual file content, not
merely a filename.

## 20.1 Security

Attachments participate in:

-   authorization;
-   audit history;
-   backup;
-   restore;
-   encryption;
-   retention;
-   household privacy.

A member who cannot see a transaction must not discover its attachment
metadata or content.

## 20.2 OCR

Future local/private OCR may suggest:

-   payee;
-   amount;
-   date;
-   candidate category.

OCR output is a proposal. User confirmation is required before financial
state changes.

------------------------------------------------------------------------

# 21. Repository and Deployment Architecture

Budget App is **deployment-independent** at the product layer.

The repository contract defines the capabilities required by the
canonical application. Different repository implementations may expose
different infrastructure capabilities without changing accounting
semantics.

## 21.1 Mode A - On-Device Personal Mode

For a single user who only needs the phone:

``` text
iPhone
├── Budget App
├── Authoritative local financial database
├── Attachments
└── Backup subsystem
```

No external server is required.

This is a full legitimate product mode, not a crippled offline/demo
mode.

The local repository must preserve the same accounting semantics as
shared/server mode.

The user may later migrate the household to Budget Server without
rebuilding the budget.

## 21.2 Mode B - Easy Home Server

A household may run Budget Server on a computer at home.

Supported target platforms should include:

-   macOS;
-   Windows;
-   Linux.

Advanced deployments may include:

-   NAS;
-   Docker/container environments;
-   virtual machines.

The normal consumer workflow should be approximately:

``` text
Download
-> Install
-> Open Budget Server
-> Create/Restore Household
-> Pair Devices
-> Done
```

Ordinary users should not need to manually install or operate
database/runtime dependencies.

## 21.3 Mode C - Remote Self-Hosted Server

The same Budget Server may run at a user-selected remote location:

-   VPS;
-   remote Linux server;
-   remote Mac;
-   remote Windows system;
-   private VM;
-   other supported host.

The product should not artificially distinguish a home server from a
remote server at the accounting/UI layer.

Remote connections require appropriate authenticated encrypted
transport.

## 21.4 Mode D - User-Owned Cloud Storage

User-owned storage such as Dropbox may be supported as a backup/snapshot
destination and migration mechanism.

For a single-user local installation:

``` text
Phone authoritative DB
       |
encrypted backup/snapshot
       |
User-owned cloud storage
```

A synchronized cloud folder is **not** automatically a multi-user
transactional database.

Budget App must not allow multiple devices to directly edit the same
SQLite/database file in Dropbox or equivalent storage without a
synchronization authority specifically designed to provide concurrency
and conflict semantics.

For shared multi-user operation, a server or future synchronization
authority coordinates writes.

The backup provider architecture should be extensible to destinations
such as:

-   local storage;
-   external drive;
-   NAS/network share;
-   Dropbox;
-   future user-owned storage providers.

------------------------------------------------------------------------

# 22. Multi-User Synchronization

Shared households require near-real-time propagation.

If one authorized member changes a shared category or records an
expenditure, other connected authorized clients should see the committed
result without requiring manual refresh.

Conceptually:

``` text
Dad assigns $100 to Groceries
        |
        v
Budget Server commits authoritative operation
        |
        +-> Mom's phone updates
        +-> iPad updates
        +-> Desktop updates
```

The same applies to transactions, approvals, reconciliations, and other
shared state.

A persistent change-notification mechanism such as WebSockets or an
equivalent event channel is appropriate. The exact transport is an
implementation decision.

## 22.1 Server authority

Clients do not negotiate financial truth peer-to-peer.

The shared repository/server validates:

-   permissions;
-   version/concurrency tokens;
-   invariants;
-   mutations;
-   resulting state.

## 22.2 Offline access

Clients should maintain an authorized local representation sufficient to
display the last synchronized state when the server is temporarily
unavailable.

Offline mutation support may be added carefully.

Simple offline transaction capture may queue a pending operation for
later server validation.

Allocation operations require stricter conflict handling because
multiple users may attempt to allocate the same money concurrently.

**Canonical rule:** synchronization may be asynchronous; financial truth
may not be ambiguous.

## 22.3 Conflict handling

Optimistic concurrency/versioning should prevent silent lost updates.

A conflict should produce a structured state transition or resolution
flow rather than silently overwriting another household member's work.

------------------------------------------------------------------------

# 23. Repository Contract

The canonical UI should depend on provider-neutral application/domain
interfaces.

The contract should be grouped around product capabilities rather than
network endpoints.

Representative groups:

-   Workspace snapshot/query
-   Account commands
-   Allocation/Plan commands
-   Transaction commands
-   Transfer commands
-   Payee commands
-   Target commands
-   Schedule commands
-   Category/group commands
-   Household/member commands
-   Permission/delegation commands
-   Request/approval commands
-   Reporting queries
-   Forecast/scenario queries and commands
-   Attachment commands
-   Audit queries
-   Backup/server-management capabilities where supported
-   Identity/discovery capabilities where supported

## 23.1 Contract requirements

All repositories that claim a capability must preserve:

-   exact-money semantics;
-   canonical accounting rules;
-   structured errors;
-   effective permissions;
-   version/concurrency semantics where multiple writers exist;
-   actor attribution where identity exists;
-   deterministic operation results;
-   consistent empty/loading/error representations at the application
    layer.

A repository may declare infrastructure capabilities such as:

``` text
supportsAuthentication
supportsMultiUser
supportsRealtimeSync
supportsServerAdministration
supportsRemoteAttachments
supportsCloudBackup
supportsOfflineQueue
```

The UI uses capability information to expose legitimate infrastructure
actions, not to fork into a different financial product.

------------------------------------------------------------------------

# 24. Backup, Restore, Recovery, and Portability

Backup/recovery is a core product feature.

## 24.1 Automatic backups

Supported repositories should provide appropriate automatic backup
options.

Shared Budget Server should support scheduled retained backups with
visible health.

The owner should be able to see:

-   last successful backup;
-   destination;
-   schedule;
-   retention;
-   failure state;
-   last restore verification where available.

Backup failure must become visible.

## 24.2 Manual backup

Owners should be able to create an on-demand backup without database
administration knowledge.

## 24.3 Full-fidelity backup

A full application backup should contain everything required to
reconstruct the household, including as applicable:

-   households;
-   memberships;
-   budgets;
-   accounts;
-   categories;
-   planning periods;
-   transactions;
-   splits;
-   transfers;
-   allocation history;
-   credit reserves;
-   reconciliations;
-   targets;
-   schedules;
-   payees/aliases;
-   requests/approvals;
-   delegation/allowances;
-   permissions;
-   audit history;
-   attachments;
-   relevant configuration metadata.

## 24.4 Encryption

Backups containing sensitive household financial data should support
strong encryption.

Recovery secrets/passphrases should be controlled by the household
owner.

The product must clearly explain the consequences of losing a user-held
recovery secret when no recovery mechanism exists.

## 24.5 Restore and server replacement

A normal recovery workflow should resemble:

``` text
Install Budget Server
-> Restore Existing Household
-> Select backup
-> Enter recovery secret if required
-> Verify backup integrity
-> Restore database + attachments + configuration
-> Reconnect/re-authorize household devices
```

Restore must be schema/migration aware.

Recovery should be tested, not merely assumed because backup files can
be created.

## 24.6 Export is not backup

**Export** provides human-readable/interoperable data such as CSV/JSON
and attachment copies.

**Backup** preserves complete application state for faithful
restoration.

Both are required concepts.

## 24.7 No lock-in

A household should be able to extract useful financial records in
documented open formats even if it stops using Budget App.

## 24.8 Authority

Full backup, restore, and household-wide export are Owner-level
capabilities by default.

They may be delegated explicitly but must not be available to restricted
members merely because they can use the budget.

------------------------------------------------------------------------

# 25. Profile & Settings

Profile & Settings is the canonical location for application-context and
administrative actions.

Depending on permissions and repository capabilities it may contain:

``` text
Profile
Household
Active Budget
Switch Budget
Create Budget
Budget Settings
Monthly Rollover
Members & Permissions
Server / Repository
Devices / Sessions
Backup & Restore
Export
Security
Diagnostics
Sign Out (where authentication exists)
```

Personal on-device mode may show local-storage/backup information rather
than server controls.

The normal active workspace should never require returning to a legacy
Budgets browser merely to reach settings or switch context.

------------------------------------------------------------------------

# 26. Home

Home is the budget command center.

It should summarize what requires attention without becoming a duplicate
of every other tab.

Representative content:

-   budget identity;
-   Unassigned;
-   overspent categories requiring attention;
-   underfunded/high-priority targets;
-   pending requests/approvals;
-   upcoming scheduled obligations;
-   recent Activity;
-   near-term Forecast summary;
-   relevant household alerts;
-   backup/server warnings for authorized owners where appropriate.

Home content must be permission-aware.

Home should prioritize actionable state over decorative statistics.

------------------------------------------------------------------------

# 27. Plan

Plan is the primary allocation workspace.

It should expose:

-   current planning period;
-   Unassigned;
-   category groups/categories;
-   Assigned;
-   Activity;
-   Available;
-   overspending classification;
-   target progress;
-   recommendations;
-   focus/filter views;
-   month navigation;
-   category/group creation and lifecycle;
-   category detail;
-   money movement;
-   Smart Funding preview/apply;
-   relevant scheduled obligations.

Useful focus views include concepts such as:

-   All
-   Underfunded
-   Overspent
-   Funded
-   Money Available

The exact labels should follow Budget App terminology and usability
testing.

------------------------------------------------------------------------

# 28. Accounts

Accounts is the location-centric financial workspace.

The account list should distinguish Budget and Tracking accounts and
display useful current state.

An account register should support, as appropriate:

-   working/current balance;
-   cleared/uncleared state;
-   reconciliation status;
-   transactions;
-   splits;
-   transfers;
-   payees;
-   flags/tags;
-   notes;
-   attachments;
-   actor attribution;
-   search/filtering;
-   reconciliation;
-   account settings/lifecycle.

Credit-card registers additionally expose payment reserve/debt state.

Tracking accounts may use specialized transaction/balance-update
workflows where necessary.

------------------------------------------------------------------------

# 29. Deterministic Sample Repository

The Deterministic repository is the canonical sample/reference dataset
provider.

It must use the same canonical workspace, views, editors, terminology,
and application services as other repositories.

It exists to:

-   demonstrate the intended product;
-   provide stable sample data;
-   support screenshots/testing;
-   exercise major workflows without requiring a server.

It must not:

-   become a separate Demo application;
-   preserve alternate accounting semantics;
-   bypass shared application logic merely for convenience;
-   imply capabilities that the product specification rejects.

Where the sample dataset intentionally demonstrates a future canonical
capability not yet implemented by the server - such as richer loan
metadata - that capability should be explicitly classified as
**canonical but not yet implemented everywhere**, not silently faked.

Known historical Demo inconsistencies such as categorized-refund
handling, credit reserve mutation divergence, and reconciliation
behavior must be corrected to the canonical rules in this specification.

------------------------------------------------------------------------

# 30. Current Reference UX vs. Required Product Behavior

The current code inventory identified a shared five-tab workspace as the
intended canonical surface:

``` text
Home
Plan
Activity
Accounts
Insights
Profile & Settings
```

The current reference implementation already contains meaningful
versions of:

-   Plan;
-   targets;
-   Smart Funding;
-   scheduled transactions;
-   transaction entry;
-   transfers;
-   account registers;
-   reconciliation;
-   credit-card concepts;
-   spending donut;
-   funding requests;
-   delegated-domain concepts.

However, current implementation status is not the specification.

Known gaps include:

-   household/delegation not fully demonstrated in the canonical
    snapshot;
-   credit-card reserve behavior differing across old/new Demo mutation
    paths;
-   categorized positive inflows not consistently restoring category
    Available;
-   reconciliation UI and deterministic behavior divergence;
-   shallow month-ledger behavior relative to the intended model;
-   Insights missing net-worth and historical trend experiences;
-   incomplete account lifecycle;
-   incomplete first-class payees;
-   metadata-only attachments;
-   no complete normal-user server installer/manager;
-   no complete backup/restore product;
-   no complete device pairing;
-   unresolved human runtime routing discrepancy in v0.4 stabilization.

These are implementation gaps, not reasons to weaken the specification.

------------------------------------------------------------------------

# 31. Financial Invariants

The following invariants are canonical requirements. Some are already
established in the existing accounting engine; others become explicit
requirements for future implementation and testing.

## 31.1 Allocation conservation

Allocation postings for a balanced allocation operation sum to zero.

Assignments and category moves do not create cash.

## 31.2 Unassigned truth

Unassigned represents real on-budget money without a category purpose.

Future income, tracking assets, available credit, and scenario values
cannot inflate Unassigned.

## 31.3 Transfer conservation

Paired account transfer legs sum to zero absent explicitly represented
fees/gains/losses.

Transfers do not create income/spending merely because money changed
accounts.

## 31.4 Split conservation

Transaction splits must sum exactly to the parent transaction amount
according to the canonical sign convention.

## 31.5 Planning neutrality

Creating/editing a Target or an unrealized Scheduled Transaction does
not change current cash, Unassigned, Available, or actual account
balances.

## 31.6 Credit conservation

Funded credit spending reserves existing cash.

Credit payment does not create a second expense.

Refund/edit/delete paths must rebuild/release reserve attribution
exactly once.

## 31.7 Delegation conservation

Delegated authority cannot exceed the money/authority actually granted.

Delegation cannot draw unrestricted household Unassigned unless
explicitly authorized by the operation.

Approval funds an approved request exactly once.

## 31.8 Reconciliation explicitness

Reconciliation does not manufacture money silently.

A difference requires review or an explicit authorized adjustment.

## 31.9 Future actual prohibition

An expected future event is not an actual transaction.

Future-dated actuals should be rejected or represented through an
explicit pending/scheduled mechanism rather than altering current
financial truth.

## 31.10 Cash overspending representation

At month transition, unresolved cash overspending is represented exactly
once according to the budget's configured rollover policy.

## 31.11 Tracking isolation

Tracking-account value contributes to net worth but not Unassigned or
ordinary category funding.

## 31.12 Actor integrity

Where identity exists, a material mutation has an authenticated actor.
Audit attribution cannot be edited as an ordinary note.

## 31.13 Permission non-leakage

A user must not infer inaccessible financial resources through
aggregates, reports, search, Activity, attachments, forecasts, or
synchronization events.

## 31.14 Concurrency

A shared repository must prevent silent lost updates and double-spending
of allocation authority.

PostgreSQL/shared-server concurrency guarantees must be tested on the
actual concurrency-capable database, not inferred solely from SQLite
tests.

------------------------------------------------------------------------

# 32. Self-Hosting and Budget Server

Budget Server is the shared-household authority for server-backed
deployments.

## 32.1 Normal-user installation

The graphical installation/management experience should hide:

-   database installation;
-   runtime installation;
-   migrations;
-   environment variables;
-   secret generation;
-   service managers;
-   command-line launchers.

Budget Server should manage:

-   initialization;
-   database lifecycle;
-   migrations;
-   service startup/restart;
-   autostart;
-   secrets;
-   network status;
-   TLS/pairing support;
-   backup status;
-   update status;
-   diagnostics.

## 32.2 Advanced installation

Docker/container and developer workflows may remain available.

Advanced options do not excuse the absence of a normal-user experience.

## 32.3 Pairing

Shared household devices should support a user-friendly
connection/pairing experience rather than requiring ordinary users to
manually copy raw URLs and long-lived secrets.

A future pairing flow may use QR codes, named servers, short-lived
pairing credentials, and explicit device/session revocation.

------------------------------------------------------------------------

# 33. Data Ownership, Security, and Privacy

Budget App contains highly sensitive household data.

Security requirements include:

-   authenticated server sessions for shared mode;
-   revocable sessions/devices;
-   server-authoritative permission enforcement;
-   encrypted transport for remote/shared connections;
-   protected secrets;
-   secure attachment access;
-   encrypted backups where configured/required;
-   no secrets embedded in logs or exports by default;
-   least-privilege access;
-   auditability of administrative actions.

Personal on-device mode should use platform-provided secure storage and
device protections where appropriate.

------------------------------------------------------------------------

# 34. Imports and Bank Connectivity - Future Boundary

Bank connectivity is intentionally deferred.

The architecture should preserve an import-staging boundary:

``` text
External candidate data
        |
        v
Match / dedupe / normalize
        |
        v
User review / explicit rules
        |
        v
Authoritative transaction operation
        |
        v
Accounting engine
```

Imports may never bypass:

-   reconciliation semantics;
-   permissions;
-   audit;
-   exact-money rules;
-   credit reserve logic;
-   transfer matching;
-   duplicate detection;
-   authoritative transaction commands.

First-class Payees and aliases should support future description
normalization.

------------------------------------------------------------------------

# 35. Intelligence Layer - Future Boundary

AI is advisory.

AI may:

-   explain spending patterns;
-   summarize household changes;
-   propose category adjustments;
-   suggest targets;
-   propose scenarios;
-   help classify transactions;
-   identify anomalies;
-   explain forecasts;
-   translate natural language into a proposed deterministic operation.

AI may not independently redefine:

-   account balances;
-   Unassigned;
-   Available;
-   credit reserve;
-   reconciliation state;
-   permissions;
-   audit history.

**Canonical rule:** AI advises; the deterministic engine decides.

------------------------------------------------------------------------

# 36. Product Acceptance Model

A capability is not complete merely because an endpoint, model, or view
exists.

For a production capability to count as complete, it should be evaluated
across:

1.  **Domain semantics** - defined and invariant-safe.
2.  **Repository/backend** - persists and reloads correctly.
3.  **Authorization** - correct visibility and authority.
4.  **Canonical UI** - discoverable and usable.
5.  **Cross-provider behavior** - same financial semantics.
6.  **Error/empty/loading states** - intentional.
7.  **Audit** - actor/history captured where required.
8.  **Synchronization** - correct in shared mode where applicable.
9.  **Human acceptance** - verified in the real production app, not only
    agent/unit tests.

Engineering verification does not equal human acceptance.

------------------------------------------------------------------------

# 37. Version and Roadmap Direction

This specification defines the destination; releases may implement it
incrementally.

Current roadmap direction:

-   **v0.4** - stabilize core budgeting workflow and canonical
    application architecture.
-   **v0.5** - transaction system completion and first-class payees.
-   **v0.6** - comprehensive Insights/reporting and interactive
    drill-down.
-   **v0.7** - household/daily UX, permissions, delegation, audit
    experience.
-   **v0.8** - richer debt/loan modeling, forecasting, scenarios.
-   **v0.9** - graphical server manager, installation, pairing,
    backup/restore/portability.
-   **v0.95** - distribution/security/recovery hardening.
-   **v1.0** - normal-user-ready local-first/user-owned product.
-   **v1.x** - imports and bank connectivity after the core system is
    trustworthy.
-   **v2.x** - intelligence/advisory layer and broader platform
    expansion.

Milestone boundaries may change. The product principles and financial
invariants should not be casually weakened to hit a version number.

------------------------------------------------------------------------

# 38. Owner Decisions - Locked

The following product decisions are authoritative as of this
specification.

## D01 - Cash overspending rollover

Per-budget user choice: - absorb into next month's Unassigned; or -
carry the category deficit.

Never both.

## D02 - Starting balances

Starting balance is first-class account creation behavior. Positive
on-budget opening cash becomes Unassigned.

## D03 - Budget vs. Tracking accounts

Both are first-class. Tracking accounts contribute to net worth but not
allocation money.

## D04 - Canonical Demo may lead implementation

Intentional Demo concepts such as richer loan/asset metadata and
category icons should be promoted into the specification rather than
removed merely to match an incomplete backend. Demo bugs are not
canonical.

## D05 - Canonical term: Unassigned

Use **Unassigned** for real on-budget money without a category purpose.

## D06 - Active-budget workspace

A budget is application context, not a normal child screen of a Budgets
browser. One budget auto-opens; multiple budgets resolve via persisted
choice or picker; switching lives in Settings.

## D07 - Household ownership boundary

Household is the ownership/security boundary. Members belong to the
household; independently permissioned budgets live beneath it.

## D08 - Payees

Payees are first-class household-owned entities with aliases, history,
rename/merge support, and optional categorization defaults.

## D09 - Real monthly planning periods

Months are persistent planning periods. Future months may allocate
existing money but never anticipated income.

## D10 - Refunds/reimbursements

Categorized positive transactions restore category money. Uncategorized
income becomes Unassigned. Refunds/reimbursements do not inflate
earned-income reporting.

## D11 - Credit cards

Purchases are categorized spending; payments are transfers; funded
purchases create payment reserve; unfunded purchases create debt.

## D12 - Reconciliation

Reconciliation verifies reality and never silently forces a match.
Adjustments are explicit, authorized, and auditable.

## D13 - Scheduled transactions

Schedules predict; transactions record reality. Due date alone does not
change actual balances.

## D14 - Targets

Targets guide funding but do not own money. Smart Funding previews
deterministic recommendations before confirmation.

## D15 - Insights

Insights must reach mature allocation-budget reporting breadth and
exceed it with interactive chart options, deep drill-down, budget
performance, debt, resilience, household-aware filtering, and export.

## D16 - Activity

Activity is the broader auditable financial timeline. Account registers
remain transaction-focused.

## D17 - Delegation and attribution

Delegation uses pre-funded household authority with fine-grained
autonomy, allowances, and requests/approvals. Multi-user financial
mutations visibly record who did what.

## D18 - Account lifecycle

Accounts with history are closed/archived, not erased. Empty accidental
accounts may be deleted.

## D19 - Attachments

Optional first-class attachments are stored by the user's
repository/server, permissioned, audited, backed up, and eligible for
future local/private OCR assistance.

## D20 - Forecast vs. Scenario

Actual, Plan, Forecast, and Scenario are distinct. Forecasts and
scenarios never create spendable money or silently modify the ledger.

## D21 - Deployment, synchronization, backup, and ownership

Budget App supports: - full on-device personal operation; - easy home
server; - remote Mac/Windows/Linux server; - advanced self-hosting; -
user-owned cloud storage as encrypted backup/snapshot storage; -
migration between supported modes; - near-real-time multi-user
synchronization through an authoritative shared repository; - offline
cached access and carefully controlled future offline mutation; -
automatic encrypted backup, full restore, open export, and server
replacement.

## D22 - Negative Unassigned

Unassigned is the net unallocated position. Positive means real money
remains to assign, zero means all allocatable money has purpose, and
negative means an unresolved funding deficit. Negative Unassigned never
represents future income and never creates cash.

## D23 - Reconciliation and cash-overspending independence

Reconciliation adjusts actual account reality; cash overspending records
category Activity beyond funded cash. A single loss is represented
exactly once unless two separate financial events genuinely occurred.

## D24 - Inflow allocation and reporting classification

Where a positive transaction is allocated and what that transaction
means for reporting are separate. The domain must remain capable of
distinguishing earned income, refunds, reimbursements, opening balances,
reconciliation adjustments, transfers/system events, and future explicit
types.

## D25 - Opening-balance effects

Positive on-budget cash openings increase Unassigned. Negative
credit-card openings create unfunded debt without payment reserve.
Tracking asset and liability openings affect net worth only and never
Unassigned.

## D26 - Directional transfer authority

Fine-grained permissions may independently grant `transfer_in` and
`transfer_out`; simple roles may grant both together.

## D27 - Prospective rollover policy

Cash-overspending rollover changes apply prospectively. Historical
periods retain the policy effective when their month boundary was
processed and are not silently reinterpreted by a later setting change.

------------------------------------------------------------------------

# 39. Implementation Guidance Following This Specification

The next architecture pass should **not** begin by rewriting everything.

It should first produce a conformance matrix mapping the current
codebase to this document:

``` text
Capability
| Specification requirement
| Current Demo
| Current Live UI
| Current Backend
| Current domain/invariants
| Gap
| Risk
| Recommended migration
| Human acceptance test
```

Priority order:

1.  Protect the existing authoritative accounting engine and tested
    invariants.
2.  Eliminate competing financial semantics in Demo/client paths.
3.  Establish the canonical repository/application-service boundary.
4.  Make the Deterministic repository exercise the same application
    behavior as other repositories.
5.  Fix root/session/active-budget lifecycle so the production runtime
    actually reaches the canonical workspace.
6.  Add missing canonical capabilities incrementally according to
    roadmap.
7.  Do not begin bank connectivity until local-first deployment, backup,
    synchronization, permissions, and core product acceptance are
    trustworthy.

------------------------------------------------------------------------

# 40. Reference Guidance Used in Product Design

Public YNAB guidance is an accepted behavioral reference for
understanding mature allocation-budgeting workflows, including:

-   assigning existing money to categories;
-   targets as category planning guidance;
-   scheduled transactions as future planning inputs;
-   credit-card payment budgeting;
-   reconciliation as a trust-building comparison to institution
    records;
-   focused planning views;
-   spending, net-worth, and income-vs-expense reporting;
-   interactive report drill-down.

Budget App deliberately extends beyond that reference with:

-   the canonical **Unassigned** terminology;
-   user-selectable cash-overspending rollover policy;
-   household-scoped fine-grained visibility and authority;
-   actor-attributed audit history;
-   delegated allowances and approval workflows;
-   richer tracking/loan/asset concepts;
-   interactive multi-level chart exploration by
    category/payee/transaction;
-   Forecast vs. Scenario separation;
-   on-device-only operation;
-   user-controlled home/remote server deployment;
-   real-time multi-user synchronization;
-   user-owned encrypted backup destinations;
-   full server replacement/recovery;
-   optional private attachments/OCR;
-   advisory-only AI layered above deterministic accounting.

No external product's branding, proprietary wording, visual identity, or
source code is part of this specification.

------------------------------------------------------------------------

# 41. Final Product Test

A successful Budget App should allow the following statement to be true:

> A person can install Budget App on one phone and manage a complete
> allocation budget without a server. A household can instead run the
> same product against a server they control, give each member precisely
> scoped visibility and authority, see one another's authorized changes
> in near real time, preserve who did what, reconcile the plan to
> financial reality, understand spending through interactive drillable
> reports, forecast known obligations, model hypothetical futures
> without contaminating real money, attach private financial documents,
> and recover the entire household from an encrypted backup - all
> without surrendering ownership of the financial data or requiring
> ordinary users to administer a database.

That is the product this specification defines.
