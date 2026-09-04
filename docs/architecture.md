# Architecture direction

## Components

- **iPhone app:** SwiftUI, local read cache, Keychain-held session material, and an HTTPS JSON API.
- **BudgetCore:** dependency-free Swift domain types and client-side policy helpers. Server authorization remains mandatory.
- **Application server:** versioned REST API, authentication, authorization, budgeting rules, imports/exports, and audit logging.
- **Database:** PostgreSQL for supported deployments. SQLite may be considered later for single-user local mode only if identical behavior can be maintained.
- **Desktop administration:** responsive web UI served by the application server, avoiding a separately installed desktop binary in the first release.
- **Deployment:** an OCI container plus a compose file for the application and PostgreSQL. TLS terminates at a documented reverse proxy or trusted private network.

## Core data boundaries

```text
Household
├── Membership (user + household role)
└── Budget
    ├── BudgetGrant → AccessProfile → Capability/ResourceGrant
    ├── Account → Credit Payment Category → ReserveEvent
    ├── CategoryGroup → Category → Target
    ├── AllocationOperation → balanced AllocationPostings
    ├── Transaction → Split
    ├── ScheduledTransaction (planning only)
    ├── FinancialRequest → RequestActions → AllocationOperation
    └── AllowancePlan → Splits → Issuance → AllocationOperation
```

All child records carry or can be joined unambiguously to `budget_id`. API handlers resolve active membership, budget visibility, effective capabilities, and account/category scopes before returning or mutating protected data. Existing View/Contribute/Manage grants remain compatibility bundles; an explicit access profile replaces the bundle with named capabilities and deny-by-default resource allowlists.

Actual transactions and immutable allocation postings are separate authoritative ledgers. Scheduled transactions and forecasts never enter actual balances or Ready to Assign. Delegated categories, requests, approvals, and allowances move existing allocation inside the same budget rather than creating cash or duplicate books. Credit liabilities, physical cash, and payment-category reserves remain distinct quantities.

## Security invariants

- New members receive no budget grants automatically.
- Only the household owner can grant/revoke or scope budget access.
- Revocation invalidates active sessions or advances a membership authorization version immediately.
- Unauthorized and nonexistent budget resources are indistinguishable to non-owners.
- Logs, push notification text, analytics, and crash reports do not contain hidden budget names or transaction details.
- Passwords use a memory-hard password hash; sessions are short-lived with rotating refresh tokens.
- Internet exposure requires TLS, rate limiting, secure headers, and documented update/backup procedures.
- Authorization is tested at API integration level even when equivalent client-side rules exist.

## Financial invariants

- Money uses signed 64-bit minor units; floating point is never authoritative.
- Every allocation operation has nonzero postings whose signed sum is zero.
- Account transfers create paired opposite transactions and do not create income or expense.
- Future schedules and forecasts cannot mutate actual balances or allocations.
- Funded credit purchases reserve only available category money; payments are transfers, not new expenses.
- Refunds release only the remaining reserve attributed to their spending category.
- Approval and allowance issuance lock their source state, use optimistic versions, and link to one auditable allocation operation.
- Household totals remain unchanged by category transfers, delegation, request approvals, and allowance issuance.

## Implemented delivery slices

1. Domain model and authorization contract.
2. Server skeleton, PostgreSQL schema, owner authentication, and API integration tests.
3. iPhone sign-in/server setup plus budget list.
4. Categories, assignments, and zero-based month calculation.
5. Transactions, splits, and reconciliation.
6. Invitations and the family permissions UI.
7. Containerized deployment, backup/restore, and security hardening.
8. Append-only allocation ledger, transfers, rollover, and targets.
9. Scheduled planning forecasts and funded credit-card accounting.
10. Capability scopes, delegated categories, requests, and approvals.
11. Recurring allowance plans and structured audit export.
