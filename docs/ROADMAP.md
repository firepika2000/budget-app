# Budget App Development Roadmap

> **This roadmap is authoritative for development sequencing.** Individual implementation plans and agent prompts must not silently redefine milestone scope, financial invariants, or deferred features. When implementation discoveries require a roadmap change, update this document explicitly.

Budget App is a self-hosted household financial operating system built around a money-allocation engine. It is not merely an expense tracker. The project may meet or exceed the practical budgeting capabilities people expect from products such as YNAB, but it must use original branding, terminology, wording, layouts, and interaction design. Capability comparison is not permission to copy protected product expression.

This document distinguishes the implemented baseline from future milestone scope. Detailed capability and acceptance evidence remains in the linked documents rather than being duplicated here:

- [Core behavioral parity review](ynab-core-parity-2026.md)
- [v0.4 core-completeness acceptance](v0.4-core-completeness-acceptance.md)
- [Financial invariants and enforcing tests](financial-invariants.md)
- [Architecture direction](architecture.md)
- [v0.4 Mac acceptance](v0.4.0-mac-acceptance.md)
- [Bank-connectivity readiness gate](bank-sync-readiness.md)

Some review documents are point-in-time snapshots and intentionally retain the status observed at their recorded commit. When a status differs, current code, newer acceptance evidence, and this roadmap take precedence for sequencing; the historical finding itself should not be rewritten.

## Product and financial principles

These constraints apply to every milestone:

- **Account means location; category means purpose.** Accounts record where money physically exists. Categories record what that money is intended to do.
- **Actual, planning, and forecast state remain distinct.** Current spendable reality cannot be inflated by a target, schedule, scenario, recommendation, or anticipated income.
- **Future income is not spendable.** It becomes assignable only after an ordinary authoritative transaction establishes that the money exists.
- **Positive category balances roll over.** Rollover preserves purpose; it is not new income.
- **Allocation operations are first-class.** Assignments and category-to-category moves change purpose without changing bank balances and remain distinct from account transactions.
- **Money is exact.** Authoritative monetary values use signed integer minor units, never binary floating point. Presentation-only geometry may derive floating-point values after exact totals are known.
- **Transfers conserve money.** On-budget account transfers change location, not income, spending, or category purpose.
- **Credit-card reserves are conserved and explainable.** Funded purchases, refunds, payments, edits, and deletions must preserve the mathematical relationship among liability, category availability, and payment reserve.
- **Reconciliation is explicit.** It cannot silently create or destroy money. Any adjustment is a visible, authorized, auditable transaction.
- **Delegated authority is real and pre-funded.** A spouse or child receives bounded authority over existing household allocation—not fake income, duplicated cash, or a disconnected ledger.
- **Household privacy is server-enforced.** Requests, approvals, capabilities, resource scopes, revocation, and auditability are core architecture. Client-side hiding is never the security boundary.
- **Recommendations do not mutate truth.** Smart Funding, targets, forecasts, scenarios, and later intelligence explain or propose changes; only an explicit valid financial operation changes authoritative state.
- **Self-hosting and ownership are durable requirements.** Core use cannot require a vendor SaaS account, ongoing subscription, or vendor-operated cloud service. Data must remain exportable, recoverable, and under the household's control.
- **Bank connectivity stays deferred.** The manual financial system must become mature, trustworthy, and releasable before imported financial data is introduced.

## Definition of complete

A major feature is complete only after all four gates pass. An endpoint, schema, or backend test alone does not make a user capability complete.

### 1. Accounting correctness

The financial model and invariants remain mathematically true across create, edit, delete, retry, concurrency, migration, and authorization boundaries. Exact totals reconcile to authoritative ledger records.

### 2. Production completeness

A real authenticated user can discover the capability, use it, persist it, reload it, and observe its consequences throughout the production application. Demo behavior may prove deterministic parity, but cannot substitute for the live path.

### 3. Human acceptance

The capability is understandable and usable in the actual application without requiring knowledge of endpoints, internal models, or implementation history. Simulator and live acceptance cover navigation, wording, errors, accessibility, and ordinary recovery.

### 4. Distribution reality

The capability works in an installation and operating environment appropriate to its intended user. A workflow that depends on undocumented shell commands, manually managed infrastructure, or developer intervention is not complete for normal households.

## Current baseline

The `codex/v0.4.0-stabilization` branch currently includes:

- a mature exact-money allocation and account-ledger foundation;
- financial invariant/property tests and PostgreSQL concurrency tests authored and wired into CI;
- household membership, roles, capabilities, resource scoping, and revocation;
- conserved delegated authority, requests and partial approvals, allowance policies, and audit history;
- credit-card payment categories and attributed reserve accounting;
- explicit reconciliation with guarded, auditable adjustments;
- a production account register and shared transaction editor;
- the Plan workspace, Targets UI, Smart Funding, and allocation history context;
- production Spending Breakdown using a Swift Charts donut, filters, drill-through, and transaction-backed recalculation;
- scheduled-transaction CRUD, Enter Now realization, recurrence, forecasting, and paused/reactivation lifecycle;
- one shared production SwiftUI hierarchy backed by either authenticated server data or deterministic demo data;
- forecasting/scenario foundations that remain separate from actual balances and spendable money;
- a one-command **developer** launcher, `./budget`, for backend setup, diagnostics, migrations, tests, and reload-mode serving.

The v0.4 release is not yet accepted merely because these implementation checkpoints exist. Human Xcode Simulator and authenticated live acceptance remain ongoing. Point-in-time reviews may list gaps that later branch commits resolved; use their acceptance criteria to retest the newer implementation.

Completing v0.4 live acceptance also requires an explicit, persisted development data-source selection that connects the production UI to the configured authoritative server without silently falling back to deterministic fixtures. Raw server-address entry is acceptable for this development gate only; consumer discovery and secure pairing remain v0.9 work.

## Release sequence

### v0.4 — Core Budgeting Stabilization

**Objective:** finish and human-validate the core budgeting workflow before opening another large subsystem.

Acceptance concentrates on the Account Register, Plan, Targets, Spending visualization, Scheduled Transactions, paused/reactivated schedules, Enter Now, Forecast, transfers, credit-card behavior, future-income isolation, persistence/relaunch, profile presentation, and reliable money entry.

The release must demonstrate that:

- actual balances, RTA, category Available, activity, and reserves remain correct through ordinary workflows;
- Targets and schedules persist and reload without becoming spendable money;
- paused schedules remain manageable but do not appear as active forecast occurrences;
- Enter Now uses the ordinary server transaction path exactly once;
- transfers and card payments do not become duplicate spending;
- delegated members see and mutate only authorized resources;
- production and deterministic demo modes use the same product hierarchy;
- serious crashes and previously discovered profile/money-entry regressions stay closed.

Accounting errors, persistence failures, serious crashes, incorrect authorization, privacy leaks, future-income leakage, and money-conservation failures block release. Cosmetic issues may be deferred unless they prevent normal use or comprehension. The detailed release gate is maintained in [v0.4 core-completeness acceptance](v0.4-core-completeness-acceptance.md) and the hands-on scripts linked above.

### v0.5 — Transaction System + Payees

**Objective:** make transactions a mature everyday workflow.

Scope includes:

- complete expense, income, transfer, credit-card payment, refund/reimbursement, and split workflows;
- memo, date, account, category, payee, cleared/reconciled state, flags, and appropriate attachments;
- explicit duplicate, delete, and void semantics with auditable derived-state reversal;
- converting to or from scheduled behavior where the accounting meaning is unambiguous;
- production search, filter, sort, pagination, and safe bulk operations;
- first-class Payee management, including rename and merge;
- optional default-category behavior backed by deterministic, explainable rules;
- payee history and useful statistics without leaking restricted transactions.

Existing transaction capabilities are the starting point, not proof that the mature workflow is accepted. Every edit/delete/bulk path must rebuild category, account, report, and card-reserve consequences exactly once.

### v0.6 — Insights & Reporting

**Objective:** complete a serious, explainable reporting layer.

Scope includes:

- Spending Breakdown and Spending Trends;
- Income vs Spending and Net Worth;
- target/goal insights;
- category, group, payee, account, and authorized-member filters where appropriate;
- drill-through from every aggregate into its authoritative contributing transactions;
- exact totals, explicit date boundaries, and understandable empty/error states;
- consistent exclusion of on-budget transfers and correct refund/split treatment.

The production Spending Breakdown donut and current analytics endpoints are an implemented foundation. This milestone expands and human-validates the complete reporting family rather than replacing server accounting with client recomputation.

### v0.7 — Daily UX + Household Experience

**Objective:** make the application comfortable for a household to use every day.

Scope includes:

- Home as an actionable command center with quick actions and needs-attention workflows;
- pinned/favorite categories and focused planning views;
- Hide Amounts and coherent privacy behavior across UI and accessibility output;
- clearer member, role, capability, account, and category-scope management;
- delegated budgets, allowances, and transparent funding rules;
- complete Requests lifecycle, including cancellation, expiration, decision history, and recovery;
- household controls expressed in human terms while retaining deny-by-default server enforcement.

### v0.8 — Debt, Loans & Advanced Forecasting

**Objective:** support long-lived liabilities and safe planning under uncertainty.

Scope includes mortgages, auto loans, student loans, personal loans, credit-card debt planning, amortization, principal/interest, payoff projections, extra-payment scenarios, and debt targets. Forecasting grows to deliberate 30/60/90-day, six-month, and one-year views plus what-if scenarios for temporary income loss, major purchases, and changed recurring costs.

Forecast and scenario state must never mutate or inflate current spendable reality. A scenario changes authoritative state only when the user explicitly commits a valid financial action through the normal engine.

### v0.9 — Distribution, Installation & Server Manager

**Objective:** make self-hosting operable by a normal household, not only by developers and infrastructure specialists.

#### Distribution, Installation & Server Manager

> A nontechnical household user must be able to install, initialize, operate, update, back up, restore, and uninstall Budget Server without using Terminal or manually installing or configuring Python, PostgreSQL, Homebrew, Alembic, Uvicorn, environment files, secrets, or other development infrastructure.

Expected normal-user flow:

`Download → Install → Open → Create Household → Done`

The normal user must not need to understand Homebrew, Python, pip, virtual environments, PostgreSQL administration, Alembic, Uvicorn, JWT secrets, `.env` files, shell commands, or raw database URLs. The future graphical Budget Server application manages internally:

- database/storage provisioning without prematurely exposing or locking in a particular implementation;
- secure secret generation and storage;
- forward migrations, startup, shutdown, and optional auto-start after reboot;
- health, storage, backup, network, and update status;
- one-click and automatic backup, restore, integrity verification, and safe recovery;
- understandable network/firewall guidance, local discovery, device pairing, diagnostics, and device revocation;
- signed and notarized distribution where appropriate;
- upgrade and uninstall behavior that clearly preserves or removes user data by explicit choice.

Three deployment experiences remain distinct:

1. **Developer deployment:** `./budget` is a convenience for contributors. It is not consumer distribution.
2. **Normal household deployment:** a native graphical Budget Server installer/manager with no Terminal requirement.
3. **Advanced self-hosting:** documented Docker/container, NAS, and server deployment for technical users.

Secure remote access must not instruct ordinary users to expose a raw application port directly to the public Internet. Pairing, discovery, recovery, encryption, firewall prompts, and off-device backup strategy require explicit threat modeling and human acceptance.

### v0.95 — Security, Reliability & Release Hardening

**Objective:** prove the assembled system can protect and recover a household's financial record.

Scope includes:

- installer and updater safety;
- forward-migration compatibility plus rollback/recovery strategy;
- backup integrity verification and repeated restore testing;
- secure secrets and device revocation;
- authorization audit and IDOR/resource-scoping review;
- corruption, interruption, and recovery testing;
- crash handling, observability, understandable diagnostics, and support artifacts;
- installation, upgrade, uninstallation, and first-run testing;
- documentation reconciliation;
- human acceptance by nondeveloper users where feasible.

Recovery must prioritize preservation of authoritative data. A failed update cannot silently reset a database or discard audit history.

### v1.0 — First Normal-User Self-Hosted Release

**Definition:** a normal household can install, operate, understand, back up, restore, upgrade, and trust the system without developer assistance.

Ordinary v1.0 use must not require Terminal. The four completion gates apply to the product as a whole, including installation and recovery—not only to budgeting screens.

### v1.x — Import & Bank Connectivity Ecosystem

Bank connectivity remains intentionally deferred until after v1.0 readiness unless this roadmap and the [bank-connectivity readiness gate](bank-sync-readiness.md) are explicitly amended and approved.

File import can evolve independently of live connectivity, including CSV and OFX/QFX where reasonable. All imports use a provider/format abstraction and enter a staging workflow as candidate evidence. Matching, deduplication, categorization suggestions, user review, and explicit ledger posting occur before imported data becomes authoritative. Imported data cannot bypass reconciliation, household scopes, audit history, or any financial invariant.

Live providers require the security, token, retention, webhook, outage, and removal controls in the readiness gate. Provider-specific semantics must remain outside the financial ledger.

### v2.x — Intelligence and Financial Operating System Expansion

Potential work includes unusual-spending and duplicate detection, recurring-bill/subscription discovery, categorization suggestions, cash-flow warnings, target recommendations, paycheck-allocation recommendations, explanations of spending changes, debt-strategy comparison, and advanced financial-health guidance.

**AI advises. The deterministic financial engine decides.** No AI or language model may invent money, silently post transactions, override permissions, or directly redefine financial truth.

## Cross-cutting product direction

### Financial Health

Potential transparent metrics include emergency runway, savings rate, debt-to-income ratio, fixed-expense ratio, upcoming-obligation coverage, and credit-card coverage. Each metric must explain what it means, how it is calculated, what changed, and what actions could improve it. Avoid opaque proprietary scores or advice that cannot be reconciled to visible authoritative data.

### Device Pairing and Networking

Normal users should not type raw IP addresses and ports. Preferred future onboarding includes local server discovery, a named household/server, an understandable Connect action, QR pairing, secure credential establishment, and explicit device revocation. Remote access should eventually be secure without requiring direct public exposure of application ports.

### Backup, Restore, and Portability

Financial-data recovery is a core feature, not an administrator afterthought. The product direction includes one-click and automatic backups, retention controls, integrity verification, encryption, an understandable restore workflow, migration-safe restore, documented exports, and off-device recovery guidance. Users own their financial data; product design must avoid artificial lock-in.

### Platform Expansion

After the iPhone and server foundation is mature, possible expansion includes iPad, macOS, web, Android, widgets, and notifications. Shared financial and domain logic should remain presentation-independent where practical. Platform count must not outrank correctness, recovery, or the quality of the primary household workflow.

## Deferred and explicitly not yet authorized

Agents and implementation plans must not begin the following merely because adjacent foundations exist:

- live bank sync, institution OAuth, credential aggregation, or screen scraping before post-v1.0 readiness and explicit approval;
- advanced AI before deterministic core workflows and explainability are mature;
- broad platform expansion before the iPhone and server foundation is strong;
- unnecessary vendor SaaS infrastructure or any required subscription dependency;
- premature visual polish that delays money correctness, privacy, persistence, or recovery;
- speculative infrastructure that contradicts self-hosting and data ownership.

## Living roadmap policy

- This roadmap governs development sequencing and milestone intent.
- Implementation plans, coding-agent prompts, and review assignments must align with it.
- Agents must not silently move deferred features into an earlier milestone.
- Agents must not redefine financial invariants or weaken acceptance gates.
- Milestone scope changes only through an explicit update to this document.
- Implementation discoveries may justify resequencing, but the discovery and decision must be documented.
- A feature is not done merely because backend code, a schema, or an endpoint exists.
- Human acceptance is part of completion.
- Release tags correspond to actual milestone acceptance, not aspirational scope or code volume.
- Security, data recovery, and distribution findings may block a release even when product screens appear complete.

The roadmap is a living document, but changing it is a deliberate product decision—not an incidental side effect of implementation.
