# Product, Commercial, Pricing, and App Store Strategy

Status: authoritative product-commercial direction; pricing and App Store structure remain hypotheses until launch validation.  
Research snapshot: 2026-09-17. Reverify all external prices, platform rules, commissions, and metadata requirements before launch.

## North star

Budget App is a privacy-conscious, auditable personal and household financial-planning system. It combines zero/envelope-based budgeting with mature transaction management, forecasting, debt intelligence, household controls, explainable automation, and flexible data ownership.

Mature products such as YNAB are capability and usability benchmarks, not the maximum specification and not templates for copied branding, language, layout, or interaction design. Product planning pursues both:

1. **Parity:** do not omit mature budgeting workflows users reasonably expect.
2. **Differentiation:** go beyond category budgeting where privacy, exact accounting, household authorization, debt intelligence, forecasting, auditability, and provider-neutral ownership create meaningful value.

## Commercial promise

> **Buy it once. Own it. Keep using it.**

A purchase grants perpetual use of the purchased core application functionality. Core budgeting must not require monthly or annual payments, and purchased functionality must not later be disabled to force recurring revenue. The paid core contains no artificial advertising, and ordinary privacy is not a recurring premium.

“Perpetual” means continued access to the purchased software version and its purchased core capabilities. It does not promise every future major version, unlimited third-party API use, unlimited vendor storage, bank-connectivity costs, or permanent vendor hosting at no cost. Software ownership and ongoing external services are separate promises and must be described separately at purchase time.

Existing owners retain their purchased entitlement when the standard price changes. A future major version may be an optional paid upgrade, potentially discounted for existing owners; the purchased prior major version continues working. Exact upgrade mechanics remain undecided.

## Core and service entitlement boundary

| Core perpetual product | Optional cost-bearing service |
|---|---|
| Budgets, accounts, categories, targets | Automatic bank aggregation with recurring provider fees |
| Transactions, splits, transfers, reconciliation, Payees, schedules | Vendor-hosted synchronization |
| Insights, reports, debt analysis, forecasting, explainable recommendations | Vendor-hosted backup, attachment storage, or compute |
| Household features that operate without vendor recurring infrastructure | External AI/API features with material per-use cost |
| Local Device and self-hosted Server providers | Other clearly disclosed third-party services |
| Import/export, user-controlled backups, user-controlled attachments | |

Optional services must never be prerequisites for ordinary budgeting. Before choosing any recurring model, evaluate pass-through/cost-based access, prepaid service packs, and user-provided infrastructure. A user who never purchases an optional service must retain the perpetual core.

## Pricing hypotheses

The preferred standard-price hypothesis is **$79.99 USD once**, with a deliberate **$59.99 introductory lifetime price**. Research bands are $59.99, $69.99, $79.99, $89.99, and $99.99. These are planning inputs—not implemented prices or promises. Final pricing requires TestFlight feedback, willingness-to-pay research, conversion and refund evidence, support-cost estimates, and final App Store configuration.

As of this research snapshot, [YNAB lists $109 USD annually or $14.99 monthly](https://www.ynab.com/pricing/), plus applicable tax. That price is time-sensitive and must be reverified before any public comparison.

| Retention period | Budget App at $79.99 once | Annual competitor at $109/year | Difference at current prices |
|---:|---:|---:|---:|
| 1 year | $79.99 | $109.00 | $29.01 |
| 2 years | $79.99 | $218.00 | $138.01 |
| 3 years | $79.99 | $327.00 | $247.01 |
| 5 years | $79.99 | $545.00 | $465.01 |
| 10 years | $79.99 | $1,090.00 | $1,010.01 |

This is a cumulative-price illustration, not a prediction that either product, price, tax treatment, or feature set will remain unchanged. Public positioning should be respectful: premium financial software without a permanent subscription—not “cheap YNAB.”

### Illustrative App Store economics

Apple currently describes a 15% commission on paid apps and in-app purchases for eligible participants in the [App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/), subject to eligibility and regional terms. The ordinary 30% illustration is included for conservative planning. Proceeds below exclude taxes, currency conversion, refunds, and other adjustments.

| Customer price | Approx. proceeds at 15% | Approx. proceeds at 30% |
|---:|---:|---:|
| $59.99 | $50.99 | $41.99 |
| $69.99 | $59.49 | $48.99 |
| $79.99 | $67.99 | $55.99 |
| $89.99 | $76.49 | $62.99 |
| $99.99 | $84.99 | $69.99 |

Eligibility, agreements, associated developer accounts, thresholds, taxes, and regional commercial terms must be reviewed in App Store Connect before pricing decisions.

## Launch purchase structure

Two structures remain under evaluation:

| Structure | Advantages | Risks |
|---|---|---|
| Paid app | Clearest buy-once message; no paywall; minimal entitlement surface | High acquisition friction; no pre-purchase product experience |
| Free download plus non-consumable Lifetime Unlock | Demo before purchase; lower download friction; restorable purchase; measurable funnel | Requires trustworthy entitlement/paywall design; free experience must be useful and honest |

The preferred hypothesis is **free download + complete deterministic Demo/evaluation + one-time non-consumable Lifetime Unlock**. Production personal budgets and persistent production providers would require the unlock. Do not collect substantial personal financial data and then demand payment for retrieval or export.

If adopted, entitlement design must support Restore Purchases, transaction verification, refunds/revocation, and durable offline use without continuous vendor-server contact when StoreKit evidence permits it. Apple documents restoring non-consumables through the normal transaction flow; implementation belongs to a later explicitly scheduled commercial milestone, not current feature work.

## Household licensing

Product principle: a legitimate household should not be charged per spouse or child for reasonable family use.

Apple currently permits developers to enable Family Sharing for non-consumable purchases, potentially sharing with up to five family members. [Apple's guidance](https://developer.apple.com/documentation/storekit/supporting-family-sharing-in-your-app) requires normal purchased/restored transaction handling and revocation handling; users also control purchase sharing, and access can change when family membership or sharing changes. Enabling Family Sharing for an IAP cannot currently be reversed.

Therefore Family Sharing is the preferred platform hypothesis, not yet a final entitlement architecture. Budget App's household authorization remains distinct from App Store purchasing identity. Self-hosted household access, cross-platform ambitions, refunds, family changes, and offline recovery require a written entitlement threat model before implementation.

## Trial and trust rules

- Demo should expose meaningful major workflows using the same production hierarchy.
- Demo data must remain unmistakably non-authoritative.
- Evaluation limits must be stated before a user enters real data.
- Export and deletion behavior must be clear; personal data is never held hostage.
- Purchase recovery must be discoverable.
- Entitlement checks must fail safely without destroying budgets or attachments.
- No invasive third-party advertising or marketing tracker is required to evaluate the product.

## App Store positioning

Primary promise: **Budgeting without another subscription.**  
Supporting language: **Your money. Your data. Your plan.**

Supporting differentiators include buy-once ownership, zero/envelope budgeting, debt-payoff intelligence, household controls, forecasting, audit history, attachments, Local Device/self-hosted choices, privacy controls, and explainable Smart Funding. Advertise only functionality actually shipped in the submitted build.

Do not rename the application without human approval. Subtitle candidates for research include “Budgeting Without Subscriptions,” “Own Your Budget,” “Private Personal Budgeting,” and “Budget, Debt & Net Worth.” Candidate keyword themes include budget, personal finance, expense tracker, spending, debt payoff, net worth, envelope budget, zero-based budget, household budget, money manager, and finance tracker. Avoid competitor trademarks and unnatural keyword stuffing.

### Screenshot narrative

1. Take Control of Your Money — Home/Plan
2. Buy Once. Keep It. — lifetime ownership
3. Give Every Dollar a Job — Plan
4. See Where Your Money Goes — Insights
5. Understand What Debt Really Costs — Debt & Interest
6. Plan a Way Out — payoff scenarios
7. Built for Households — understandable access controls
8. Your Data, Your Choice — only after Local/Server/backup experiences are production-ready

A 20–30 second preview should show Home, Plan, a transaction, Insights, Debt, and privacy/appearance with one concise message: buy once, budget clearly, understand your money. Asset production is deferred.

## Acquisition and experimentation

[Apple Product Page Optimization](https://developer.apple.com/app-store/product-page-optimization/) can compare up to three treatments involving icons, screenshots, and previews. [Custom Product Pages](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions) can align approved variants with debt, budgeting, privacy, and household audiences. Test one meaningful variable at a time where practical.

Candidate first-screenshot tests:

- Budgeting Without Another Subscription
- Own Your Budget
- Know Where Every Dollar Goes

Apple Ads begins with a small discovery budget around high-intent budgeting, expense, debt, envelope, and money-manager themes. Debt ads lead to debt-focused pages; privacy ads to data-ownership pages; budget-planner ads to planning pages. Expansion depends on purchase conversion and sustainable acquisition cost, not download volume.

Organic work should teach before selling: budgeting and debt communities, privacy/self-hosting communities, relevant creators and newsletters, indie-app channels, and careful build-in-public communication. Never spam communities. Useful subjects include subscription economics, interest costs, avalanche versus snowball outcomes, zero-based budgeting, household privacy, and self-hosting personal finance data.

## Competitive intelligence

Maintain a dated internal matrix for Budget App, YNAB, Monarch, Copilot, Quicken/Simplifi, and other relevant products. Compare price model, budgeting, transactions, bank sync, debt, reports, household behavior, privacy, ownership, attachments, forecasting, auditability, and platforms. Every public claim requires fresh primary-source verification; do not publish an internal inference as fact.

## Launch stages and evidence

0. **Internal/human acceptance (current):** correctness, migrations, recovery, native usability.
1. **Closed TestFlight:** crashes, integrity, onboarding, pricing feedback, confusing workflows.
2. **External TestFlight:** activation, retention, discovery, and support burden.
3. **Soft launch:** product page, price, purchase funnel, refunds, reviews, and support.
4. **Public launch:** approved assets, measured ads, creator/community outreach, and education.
5. **Optimization:** product-page tests, custom pages, keywords, price evidence, and feature-led messaging.

Privacy-conscious metrics include App Store impressions/page views, download and lifetime-purchase conversion, refund rate, crash-free sessions, onboarding completion, coarse 30-day usage, support contacts, and review sentiment. Prefer App Store and first-party aggregate evidence; any product analytics require explicit privacy review and data minimization.

Request reviews only through Apple's native mechanism after a genuine positive milestone such as a completed month, successful reconciliation, or debt milestone. Never gate functionality or repeatedly pressure users.

## Support economics

One-time pricing creates a long support tail. Release readiness therefore includes excellent in-app help, searchable documentation, troubleshooting, privacy-safe diagnostics export, tested backup/restore, migration compatibility, and a defined support window for each major version. Price research must include support hours, refund causes, infrastructure cost, accessibility work, security response, and long-term OS compatibility—not only App Store commission.

## Decision gates

Before commercial implementation:

1. Complete the release, recovery, security, and distribution milestones required for trustworthy real-money use.
2. Choose paid app versus free + non-consumable unlock with human approval.
3. Define precisely which production providers are core-entitled.
4. Complete StoreKit offline/recovery/revocation and Family Sharing threat models.
5. Validate price bands and support economics.
6. Reverify competitor prices and Apple rules.
7. Approve truthful launch claims and privacy-preserving measurement.

No payment code, paywall, analytics SDK, final price, renamed product, or App Store asset is authorized by this document.
