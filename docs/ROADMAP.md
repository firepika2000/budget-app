# Budget App Development Roadmap

> **This roadmap is authoritative for development sequencing.** Individual implementation plans and agent prompts must not silently redefine milestone scope, financial invariants, or deferred features. When implementation discoveries require a roadmap change, update this document explicitly.

Budget App is a self-hosted household financial operating system built around a money-allocation engine. It is not merely an expense tracker. The project may meet or exceed the practical budgeting capabilities people expect from products such as YNAB, but it must use original branding, terminology, wording, layouts, and interaction design. Capability comparison is not permission to copy protected product expression.

Product ownership, pricing hypotheses, core-versus-service entitlements, household licensing, and App Store launch principles are governed by [Product, Commercial, Pricing, and App Store Strategy](PRODUCT-COMMERCIAL-STRATEGY.md). Core budgeting follows a buy-once, perpetual-use promise; payment implementation and final pricing require a separately approved roadmap checkpoint.

This document distinguishes the implemented baseline from future milestone scope. Detailed capability and acceptance evidence remains in the linked documents rather than being duplicated here:

- [Core behavioral parity review](ynab-core-parity-2026.md)
- [v0.4 core-completeness acceptance](v0.4-core-completeness-acceptance.md)
- [v0.4 live acceptance (current findings)](v0.4.0-live-acceptance.md)
- [Financial invariants and enforcing tests](financial-invariants.md)
- [Enforced application architecture](ARCHITECTURE.md)
- [v0.4 architecture audit](ARCHITECTURE-AUDIT-v0.4.md)
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
- **Purchased core software remains perpetual.** Ordinary budgeting cannot be converted into a mandatory recurring subscription. Optional services with real ongoing vendor costs remain explicitly separate from purchased core functionality.
- **Bank connectivity stays deferred.** The manual financial system must become mature, trustworthy, and releasable before imported financial data is introduced.
- **Empty states are part of the product, not edge cases.** A fresh household must always have an obvious next action. A new installation, a new Budget, and an empty Plan must each present a discoverable path forward and must never dead-end into a state the user cannot leave without an API or developer workaround.
- **Teach the financial model, not just the interface.** Onboarding and education explain both how to operate Budget App and why the allocation model works the way it does — money location versus purpose, and that future income helps you plan but is not spendable until it is actually received. Education never bypasses an invariant and never quietly mutates authoritative household data.

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

**Functional onboarding directly affects gates 2–4.** If a real user cannot discover how to progress from a fresh state into using a capability — for example, a new Budget with no discoverable way to create the first category — then production completeness, human acceptance, and distribution reality are not met, regardless of how correct the underlying accounting is.

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

**Live acceptance is now running against authoritative PostgreSQL state.** Hands-on testing has connected the iOS Simulator to a fresh PostgreSQL-backed Budget Server and demonstrated the live path through health/status discovery, first-owner initialization, Sign In, authenticated application entry, first Budget creation, and initial production data hydration. Detailed evidence and findings are tracked in [v0.4.0 live acceptance](v0.4.0-live-acceptance.md). **v0.4 is not complete.** Current blockers and open findings include:

- **Fresh Plan / category onboarding dead end (blocker).** A newly created live Budget has no category groups/categories and the Plan UI exposes no discoverable path to create the first one, so a new household cannot progress into normal budgeting without an API/manual workaround. See the v0.4 milestone requirement and the First-Budget Experience below.
- **iOS first-time bootstrap submission returned `422` and requires diagnosis.** The setup form (which does include a Household Name field) failed where a direct request on the documented contract succeeded; the client-side root cause is not yet known.
- **Owner Budgets empty-state wording is contextually wrong** — an authenticated owner was shown "ask the owner to share a budget" copy.
- **`GET /delegated-budgets/me` returned `404` for the owner** — semantic review pending (legitimate "no delegated budget" versus an empty-state/integration issue).
- **Remaining live persistence and financial-workflow acceptance is pending.** In particular, the intended live financial-persistence check (`$720 → $860`) has **not** been completed — it is currently blocked by the Plan onboarding dead end, since the fresh Budget has no categories to assign against.

Because CI minutes are temporarily exhausted, local verification is serving as the active gate while that capacity is unavailable; this is an engineering constraint, not a change to any acceptance gate.

## Release sequence

### Approved production-readiness mission sequence (2026-09-18)

The production-readiness mission explicitly expands the pre-v1.0 scope and supersedes the older
version numbering below. Work occurs on `codex/development`; `main` remains at the approved
`c5494dd` consolidation. Existing historical tags and human evidence are preserved, not rewritten
as acceptance for later work. No further merge or release tag is authorized by this sequence.

| Checkpoint | Engineering scope and dependencies |
|---|---|
| v0.8 | Debt Cost & Payoff and focused Insights closure. Recorded, estimated and projected values remain separate. |
| v0.9 | Planning Power: audit the existing targets, future months, focus, Smart Funding and Move Money before filling cadence, snooze and Cost of Plan gaps. |
| v0.10 | File Import Engine: CSV, OFX/QFX and QIF through bounded parsing, normalization, staging, matching, explicit approval and canonical posting. No adapter becomes an accounting engine. |
| v0.11 | Mobile Speed / Apple integrations: quick entry, App Intents, Shortcuts and widgets with explicit authorization and privacy. |
| v0.12 | Financial History / Audit: preserve immutable attribution, explain observations and close history/export gaps. |
| v0.13 | Bank connectivity architecture and feasible integration after the import engine. Credentials, provider contracts and security review remain real gates; no screen scraping or speculative live-account access. |
| v0.14 | Data Ownership: production transactional/migratable Local Device storage, encrypted/versioned backup and new-destination restore. Dropbox is a backup destination, not live SQLite sync. |
| v0.15 | Extended Forecasting: engineering complete with selectable 30/60/90-day, six-month, and one-year horizons plus ephemeral scenarios for temporary income loss, changed recurring costs, and major purchases. Future income, schedules, and scenarios remain non-spendable. Human acceptance remains distinct. |
| v0.16 | Explainable Smart Planning: engineering complete with structured per-category target type, priority, monthly recommendation, proposed funding, and remaining shortfall. Preview remains non-mutating and only explicit canonical confirmation can move money. Human acceptance remains distinct. |
| v0.17 | Household Power: engineering complete with human-readable exact scope review, requests/allowances, actor attribution, revocation handling, and adversarial privacy enforcement. Human acceptance remains distinct. |
| v0.18 | Platform Expansion: iPad engineering slice complete with the shared production workspace, adaptive sidebar/detail navigation, compact multitasking fallback, and privacy-safe widget support. macOS, web, and Android remain separate future slices; human iPad acceptance remains distinct. |
| v1.0 | Release hardening, production deployment and App Store candidate gates. External signing, commercial choice and human acceptance stay distinct from engineering completion. |

Current v0.12 progress: transaction and reconciliation histories were already durable; category-target
decisions now also retain immutable actor attribution across hosted, Local Device, Demo, complete export,
and server-to-local transfer. Category detail exposes bounded Target History without changing allocations,
balances, or recommendations. Delegated household authority now likewise retains exact, attributed before/after
snapshots of limits, capabilities and category rules, including populated-database migration, complete export,
bounded owner-only history, and Demo/Live parity. No-op saves create neither replacement rule identities nor
duplicate decisions. Account creation, rename, safe type changes, close and reopen decisions now retain the same
immutable actor-attributed history across hosted, Local Device and Demo providers, complete export and
server-to-local transfer; balances, transactions and reconciliation observations are deliberately excluded from
metadata snapshots. Category-group and category creation, rename, organization, archival, presentation,
resilience classification and delegation decisions now also retain immutable actor-attributed history across
hosted, Local Device and Demo providers, complete export and server-to-local transfer. Detail and group settings
expose bounded history without changing allocations, activity or balances. Payee creation, rename, archive,
alias, merge and budget-specific default-category decisions now retain the same immutable attributed history.
The production Payee editor exposes a bounded history view; scoped members can read history only for Payees
already visible through their authorized transactions, and hidden aliases, merge targets and category preferences
are redacted. Populated migrations, complete export, server-to-local transfer, Local Device reopen and Demo all
preserve the observations without recording transaction aggregates or changing ledger money.
Allowance-plan creation, pause, reactivation and issuance-driven schedule advancement now likewise retain
immutable actor-attributed before/after snapshots with exact minor-unit amounts and split policy. The bounded
manager-only history is available in the shared Demo/Live plan detail, populated hosted databases receive a
creation baseline during migration, and complete export includes the decisions. Issuance money remains in the
existing allowance ledger and restricted members cannot use policy history to discover hidden source or scope
details. Debt Terms now retain exact, attributed creation, update and removal history across hosted,
Local Device and Demo providers, complete export and server-to-local transfer. The shared terms editor
offers bounded history and earlier pages; local repository mutations persist before returning instead
of depending on a later workspace refresh. History observations expand to show exactly which planning
fields changed, with before/after values and explicit unset values; large money remains exact during
display, and unchanged fields are omitted. Saved payoff plans now match Live's actor-owned privacy in
Demo; current account scope and balance/report capabilities apply at read time, and one member cannot
read or reset another member's plan. Local Device preserves the actual owner and original save timestamp
through reopen and refresh.
Saved scenario requests now share bounded strategy/order/date validation before local persistence
or hosted transport; malformed edits preserve the previous scenario and cannot mutate ledger money.
Remaining v0.12 work should continue auditing other mutable
planning and administrative observations
for overwrite-only or export gaps rather than duplicating established histories.

**Consumer Budget Server distribution remains required.** The earlier v0.9 graphical installer,
manager, secure pairing and no-Terminal household operating experience below are retained as a
cross-cutting distribution workstream through v1.0; a developer launcher is not a substitute.
Local Device and server delivery both require credible recovery. Security, migration preservation,
accessibility and performance run continuously rather than waiting for a final version number.

Dependency ordering may put recovery or authorization ahead of a feature checkpoint. Version
boundaries do not authorize stopping the mission or declaring release readiness. The master gate
ledger is `PRODUCTION-READINESS.md`; every unimplemented requirement must remain open or receive
an explicit evidence-based deferral, never disappear through renumbering. StoreKit remains blocked
on the paid-download versus non-consumable Lifetime Unlock decision; independent work continues.

Dropbox engineering for v0.14 is complete in the production iPhone composition. The registered public
Dropbox app identifier is included in ordinary app builds and independently verified by the fail-closed
release script. The remaining gate is external-console confirmation (App-folder permission and redirect
URI `clearpocket://dropbox-oauth`) plus one live-provider acceptance pass. Do not treat that external gate as unfinished storage code,
and do not embed a client secret or replace immutable encrypted backup with live SQLite sync.
Verified Dropbox publication now remains successful when subsequent retention cleanup or backup-list
refresh fails. A non-fatal maintenance warning distinguishes that state from an actual upload/integrity
failure, and the successful-backup timestamp and known generation remain available without prompting
a duplicate upload.
Interrupted final-move responses and explicit retries now recover an already-published generation
only after its entire file set, sizes and content hashes match the immutable local package. A same-name
conflict still fails without overwrite, and recovery never prunes newer backups for an older retry.

The privacy-safe v0.11 launcher widget is implemented for small and medium Home Screen families and
uses the authenticated production shell for navigation. It deliberately shares no financial data or
credentials with the extension. Rich financial widgets require a future explicit disclosure,
authorization, shared-container and redaction contract; they are not implied by this launcher.

The v0.11 engineering candidate also includes one-shot Siri/Shortcuts routes for every primary
workspace surface, parameterized transaction quick entry through the shared editor, optional
non-future transaction dates, and bounded privacy-safe scheduled reminders. See
`V0.11-CLOSURE-AUDIT.md`; human acceptance remains separate.

Private receipt assistance now satisfies the product-specification proposal boundary: Vision OCR runs
locally, suggests payee, exact amount, date and a visible category, and requires both explicit Apply
and the normal transaction Save. It neither uploads the receipt nor creates financial state on its own.

Privacy-safe local reminders now cover active scheduled-item due dates without turning notifications
into another financial-data surface. They are explicitly enabled per device and budget, bounded to
the next 60 days, refreshed from authoritative schedule state, and contain only generic alert text.

Scheduled-item management now includes an explicitly confirmed Skip Next Occurrence action. It uses
the existing scoped schedule-update service, advances recurring dates with the canonical calendar
rules, pauses a skipped one-time item, and never creates a transaction or changes financial state.

Recurring schedules can now carry an optional final occurrence date across Live Server, Local Device,
Demo, export/import projection, editor and forecast paths. Forecast expansion stops at that boundary;
realizing or skipping the final occurrence pauses the schedule without creating extra financial state.

They can alternatively carry an exact remaining-occurrence count. Forecast expansion consumes only a
temporary copy of the count; Enter Now and Skip Next decrement canonical state and pause at zero.
Date and count limits are mutually exclusive, and neither changes actual money before realization.

Local Device statement-import review/history is now durable across relaunch and encrypted SQLite
backup/restore. This closes the prior session-only lifecycle gap while preserving money-neutral staging,
explicit approval and account-scoped detail access.

Bank statement import now also accepts ISO 20022 CAMT.052/.053/.054 XML in Budget Server and Local
Device modes. Entries retain exact minor-unit debit/credit values and use the same bounded,
duplicate-aware review and canonical approval path; unsafe XML declarations fail closed.

Category selection now uses qualified `Group · Category` labels throughout production transaction
entry/editing, split entry, scheduled expenses, Activity/report filters, statement-import review and
allowance setup; posted transaction detail uses the same label. Duplicate names in different groups remain distinguishable at the
point of selection without changing category identity or accounting semantics.

The sections that follow retain the original milestone scope and historical context. References
to v0.9 distribution or v1.x import in those sections use the old numbering; the table above is the
current authorized execution sequence. Human acceptance is pending and no retest is requested now.

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

#### Functional first-run onboarding (required for v0.4)

v0.4 must include enough functional onboarding and empty-state behavior that a brand-new live household can create and use its first Budget **without any API or manual intervention**. The path `new installation → household → owner → budget → accounts → categories → usable Plan` must not dead-end at any step.

Specifically for v0.4: **the Plan empty state must provide a discoverable path to create the first category group and category.** This is the functional onboarding requirement, not the polished guided tour — the complete interactive walkthrough (see [Onboarding and Product Education](#onboarding-and-product-education)) is **not** required for v0.4 and is scheduled at v0.7.

#### First-Budget Experience

A fresh Budget must offer a deliberate first-run experience with clear, discoverable actions, at minimum:

- Add your first account;
- Create your first category group;
- Add categories;
- Understand Available to Assign;
- Begin assigning real money.

For v0.4, **manual creation with excellent empty-state guidance is sufficient** — starter category templates, household-type templates, and guided setup recommendations are future possibilities and are **not** mandatory for this milestone. Any template or sample content, if later added, must respect the "empty states are part of the product" and "recommendations do not mutate truth" principles: it may propose structure but must not silently create authoritative money.

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
- household controls expressed in human terms while retaining deny-by-default server enforcement;
- the primary **Guided Onboarding & Product Education** workstream (below).

#### Guided Onboarding & Product Education (primary workstream)

v0.7 hosts the polished guided experience that teaches new users both **how** to operate Budget App and **why** the allocation model works the way it does. It is optional education layered on top of the functional first-run onboarding delivered at v0.4 — not a replacement for it. Full product direction, teaching goals, and the guided-tour requirements are in [Onboarding and Product Education](#onboarding-and-product-education); this milestone delivers:

- the polished interactive walkthrough that prefers real interaction over passive slides;
- the educational progression through the core concepts (accounts as location, Plan as purpose, future income not yet spendable) and, progressively, first account, real starting balances, category groups/categories, assigning available money, moving money between purposes, recording a transaction, watching category balances respond, targets, scheduled transactions, credit-card reserve behavior, reconciliation, forecast versus actual/current money, and Insights;
- skip, resume-where-practical, and restart-from-Profile/Help/Settings behavior;
- contextual education surfaced in-place, accessible and Dynamic Type / VoiceOver compatible;
- explicit signalling of whether an action affects real financial data, with any demonstration state confined to an identified demonstration/sandbox context or gated behind explicit user consent.

### v0.8 — Debt, Loans & Advanced Forecasting

**Objective:** support long-lived liabilities and safe planning under uncertainty.

Scope includes mortgages, auto loans, student loans, personal loans, credit-card debt planning, amortization, principal/interest, payoff projections, extra-payment scenarios, and debt targets. Forecasting grows to deliberate 30/60/90-day, six-month, and one-year views plus what-if scenarios for temporary income loss, major purchases, and changed recurring costs.

Debt cost and payoff work must preserve three separately labelled evidence classes: **Actual interest**
from explicitly classified posted history, **Estimated current interest** from persisted account terms
and current principal/balance, and **Projected future interest** from visible scenario assumptions.
v0.8 adds optional type-appropriate debt terms rather than forcing loans and credit cards into one
model. Missing terms keep an account valid and produce an explicit incomplete/unavailable projection.

The provider-neutral projection engine uses exact minor-unit accumulation with documented periodic
rate conversion and rounding. It must detect zero-rate payoff, insufficient payment and negative
amortization, and must not emit a fictional payoff date. Household simulations compare avalanche,
snowball, and user-controlled ordering by objective outcomes without prescribing a strategy. Extra
payment and payment-rollover assumptions remain visible scenario inputs and do not mutate the Plan.
Privacy filtering occurs before account or household projection, so hidden debt terms and derived
outcomes cannot contribute to restricted totals or suggestions. Detailed sequencing and financial
vectors are maintained in `V0.8-IMPLEMENTATION-PLAN.md`.

Forecast and scenario state must never mutate or inflate current spendable reality. A scenario changes authoritative state only when the user explicitly commits a valid financial action through the normal engine.

### v0.9 — Distribution, Installation & Server Manager

**Objective:** make self-hosting operable by a normal household, not only by developers and infrastructure specialists.

#### Distribution, Installation & Server Manager

> A nontechnical household user must be able to install, initialize, operate, update, back up, restore, and uninstall Budget Server without using Terminal or manually installing or configuring Python, PostgreSQL, Homebrew, Alembic, Uvicorn, environment files, secrets, or other development infrastructure.

Expected normal-user flow:

`Download → Install → Open → Create Household → Done`

v0.9 also extends onboarding into the complete normal-user self-hosted experience — the **server and device onboarding** concern (distinct from functional first-run onboarding and from guided product education; see [Onboarding and Product Education](#onboarding-and-product-education)):

`Download → Install → Open Budget Server → Create/Connect Household → Pair Device → Create/Select Budget → Begin guided onboarding`

No Terminal or development infrastructure may be exposed to normal users at any step of this flow. It covers Budget Server installation, local discovery, secure device pairing/enrollment, remote/local connectivity, and backup/recovery setup, and it hands off cleanly into the in-app guided onboarding scheduled at v0.7.

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

A nontechnical new user must be able to go from a fresh installation to a usable household Budget and understand the core allocation model (money location versus purpose; future income is not yet spendable) **without developer intervention**. Completing the optional guided tour is not required, but the product must provide sufficient discoverable guidance — functional onboarding that never dead-ends, clear empty states, and available product education — for that user to succeed on their own.

### v1.x — Import & Bank Connectivity Ecosystem

Bank connectivity remains intentionally deferred until after v1.0 readiness unless this roadmap and the [bank-connectivity readiness gate](bank-sync-readiness.md) are explicitly amended and approved.

File import can evolve independently of live connectivity, including CSV and OFX/QFX where reasonable. All imports use a provider/format abstraction and enter a staging workflow as candidate evidence. Matching, deduplication, categorization suggestions, user review, and explicit ledger posting occur before imported data becomes authoritative. Imported data cannot bypass reconciliation, household scopes, audit history, or any financial invariant.

Live providers require the security, token, retention, webhook, outage, and removal controls in the readiness gate. Provider-specific semantics must remain outside the financial ledger.

### v2.x — Intelligence and Financial Operating System Expansion

Potential work includes unusual-spending and duplicate detection, recurring-bill/subscription discovery, categorization suggestions, cash-flow warnings, target recommendations, paycheck-allocation recommendations, explanations of spending changes, debt-strategy comparison, and advanced financial-health guidance.

**AI advises. The deterministic financial engine decides.** No AI or language model may invent money, silently post transactions, override permissions, or directly redefine financial truth.

## Cross-cutting product direction

### Onboarding and Product Education

Budget App treats onboarding as three related but distinct product concerns. They must not be conflated: shipping one does not satisfy another.

1. **Functional first-run onboarding** — what a user needs to get from `new installation → household → owner → budget → accounts → categories → usable Plan`. This is not optional and must never dead-end; every empty state on that path presents an obvious next action. Its first acceptance gate lands at v0.4 (the Plan empty state must offer a discoverable path to create the first category group/category; see the v0.4 milestone and First-Budget Experience).
2. **Guided product education** — an optional walkthrough that teaches how and why to use Budget App effectively. This is the v0.7 workstream. It is layered on top of functional onboarding and is never a prerequisite for basic use.
3. **Server and device onboarding** — the later consumer self-hosted experience: Budget Server installation, local discovery, secure device pairing/enrollment, remote/local connectivity, and backup/recovery setup, with no Terminal or development infrastructure exposed. This is v0.9 (see Distribution, Installation & Server Manager).

**Teach the financial model, not just the interface.** The guided experience is not merely a sequence of tooltip bubbles; it teaches both how to operate the application and the reasoning behind the allocation model. At minimum it makes clear that *accounts tell you where your money is, your Plan tells you what that money is for,* and that *future income can help you plan ahead but is not available to spend until it is actually received.* It then progressively teaches creating the first account, entering real starting balances, category groups/categories, assigning available money, moving money between purposes, recording a transaction, seeing category balances respond, targets, scheduled transactions, credit-card reserve behavior where applicable, reconciliation, forecast versus actual/current money, and Insights. The walkthrough prefers real interaction with the application over passive slides.

The eventual guided tour must be: optional; skippable; resumable where practical; restartable from Profile / Help / Settings; accessible, including Dynamic Type and VoiceOver; and explicit about whether any action affects real financial data. It must be safe around authoritative household data: it must **never** silently create fake authoritative transactions, balances, income, accounts, or allocations. If a demonstration requires sample financial state, it must use an explicitly identified demonstration/sandbox context or obtain explicit user consent before modifying authoritative data. The deterministic/demo environment may be a useful basis for a safe interactive tutorial.

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
## Current development checkpoints

- Scheduled Transactions now retain immutable attributed decision history for create, edit,
  pause/resume, realization and deletion. The bounded production history screen shares one contract
  across Budget Server, Demo and Local Device; privacy is evaluated against both sides of a resource
  change before pagination, and exact money plus realization lineage survive export and deletion.

- The v0.10 File Import Engine is an engineering candidate across Budget Server and Local Device.
  CSV/TSV/delimited text, OFX/QFX, QIF, MT940, CAMT and conservative PDF recognition enter one
  bounded, money-neutral review flow with duplicate suggestions, explicit approval, durable history,
  cancellation and canonical undo. Direct bank connectivity remains a separate v0.13 gate. The
  checked-in app and widget identity is now 0.10.0 (6); no TestFlight upload, merge or tag is implied.

- The Add Transaction App Shortcut now supports optional payee, exact currency text, memo and
  expense/income type. It prefills the canonical transaction editor rather than maintaining a
  shortcut-only ledger path, and never saves until the user selects required context and confirms.
  Its one-shot draft is bounded and expires after five minutes. The privacy-safe launcher widget's
  Add Transaction control opens this same editor without placing private values in a widget URL.

- Plan group Suggested and Average Spent guidance follows authoritative workspace revisions while
  Plan is visible. It keeps the last authorized observation through temporary connectivity loss but
  clears it on scope denial, preventing stale cross-permission aggregates without moving money.

- The shared production workspace remembers its selected tab per Budget so foreground or route
  reconstruction no longer returns an in-progress Plan, Activity, Accounts, Insights, or Household
  task to Home. Unsaved editor drafts remain intentionally owned by their live presentation.

- Activity now surfaces the five most recent visible transaction audit events with actor, action,
  ledger date, payee context, and a concise changed-field summary. Selecting an event opens the
  existing production transaction detail and complete Change History; no duplicate editor or audit
  store was introduced. Budget Server applies account/category/split privacy before its bounded
  order/limit, while Demo and Local Device project the same immutable audit records.

- Activity now also surfaces the five most recent authorized funding-request actions—including
  submission, revision, approval, partial approval, requested changes, rejection, cancellation and
  expiry—with exact money, qualified category context, actor attribution and direct drill-through to
  the existing complete request history. It derives only from the already scoped request response;
  no new aggregate or hidden request identity is exposed. The deterministic sample now carries
  stable request-action fixtures instead of presenting status without the history that produced it.

- Dropbox backup management now lets a Local Device owner deliberately remove one encrypted remote
  generation through a separate destructive swipe/accessibility action and explicit confirmation.
  The provider boundary rejects deletion outside the configured direct-child backup folder, refreshes
  the authoritative generation list after success, and leaves the live budget and other generations
  unchanged. This complements automatic retention without turning Dropbox into a live database.

- Activity now surfaces the five most recent authorized reconciliation checkpoints across visible
  accounts, with statement balance/date, actor, and transaction count, and drills into the existing
  canonical account history. The server performs one bounded budget-scoped read and applies account
  privacy before ordering and limiting; it does not fan out into one request per account. Live,
  Demo, and Local Device use the same production presentation and preserve exact minor-unit values.

- Account reconciliation now preserves an append-only, attributed history instead of only the latest
  balance. The production account register exposes a bounded Reconciliation History view showing the
  statement date and balance, prior cleared balance, transaction count, adjustment presence, and actor.
  Existing reconciled accounts receive one conservative legacy checkpoint during migration; no ledger
  or balance is recalculated. Server-to-Local Device transfer and encrypted Local Device snapshots
  preserve those audit fields losslessly; legacy snapshots remain readable without fabricating facts.

- Transaction Change History now explains safe before/after values for ordinary edits instead of
  listing only field names. Exact money remains integer minor units until native formatting; account
  and category identities are qualified for display. If either historical snapshot was outside the
  viewer's current resource scope, that entire side is redacted rather than leaking its former payee,
  memo, amount, account, category, or split context. Raw audit JSON and internal attachment/lineage
  identifiers remain server-only.
- Transaction Change History no longer silently stops at the newest 50 events. The shared production
  view pages older authorized history on demand, and both Budget Server and Local Device providers
  honor the same bounded limit/offset contract without loading an unbounded audit trail into memory.
  A failed older-page request keeps the history already on screen and offers an explicit retry.
- Budget Server allocation history now uses privacy-before-pagination bounded reads in the current
  iPhone composition, with explicit older-history loading and readable actor attribution.
- Payee and category detail no longer stop at the workspace's bounded recent snapshot. Each now
  links to a reusable, server-authoritative transaction history that preserves its payee/category
  scope, loads older authorized rows in bounded pages, and retains already loaded history when an
  older-page request fails. Category detail also links to the complete allocation-history ledger.
- Owner-visible household access activity is a bounded, continuable audit trail rather than a
  silent 20/200-event truncation. Budget Server, Local Device/Demo and the production Members UI
  share deterministic newest-first pages; failed older-page loads retain the history already on screen.
- SWIFT MT940 statement import is production-wired across Budget Server and Local Device providers,
  preserving exact minor-unit money and the existing explicit reconciliation review boundary.
- Activity now includes the five most recent authorized Plan changes with actor attribution and a
  route to the complete immutable allocation history. Posted transactions remain separately searchable
  and filterable, so Plan changes do not masquerade as ledger activity.
- Financial Resilience now exposes average money age, net-spending burn/runway, category-classified
  essential and emergency-fund coverage, and upcoming-obligation coverage. The latter divides the
  exact visible cash buffer by authorized active scheduled outflows and deliberately excludes future
  income so a forecast cannot inflate current spendable reality.
