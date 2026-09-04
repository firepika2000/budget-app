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
    ├── BudgetGrant (user + permission)
    ├── Account
    ├── CategoryGroup → Category → MonthlyAssignment
    ├── Payee
    └── Transaction → Split
```

All child records carry or can be joined unambiguously to `budget_id`. API handlers resolve the authenticated membership and budget grant before loading or aggregating protected data. Database queries must be scoped, not fetched broadly and filtered afterward.

## Security invariants

- New members receive no budget grants automatically.
- Only the owner can grant/revoke access in the MVP.
- Revocation invalidates active sessions or advances a membership authorization version immediately.
- Unauthorized and nonexistent budget resources are indistinguishable to non-owners.
- Logs, push notification text, analytics, and crash reports do not contain hidden budget names or transaction details.
- Passwords use a memory-hard password hash; sessions are short-lived with rotating refresh tokens.
- Internet exposure requires TLS, rate limiting, secure headers, and documented update/backup procedures.
- Authorization is tested at API integration level even when equivalent client-side rules exist.

## Suggested delivery slices

1. Domain model and authorization contract.
2. Server skeleton, PostgreSQL schema, owner authentication, and API integration tests.
3. iPhone sign-in/server setup plus budget list.
4. Categories, assignments, and zero-based month calculation.
5. Transactions, splits, and reconciliation.
6. Invitations and the family permissions UI.
7. Containerized deployment, backup/restore, and security hardening.

