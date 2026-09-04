# Household financial foundation release checklist

## Automated verification

- [x] Budget authorization and derived-data privacy integration tests
- [x] Ledger, split, transfer, reconciliation, and monthly-summary tests
- [x] Invitation, revocation, rotating-session, and throttling tests
- [x] CSV isolation and formula-injection tests
- [x] Balanced allocation, rollover, targets, actual/forecast isolation, and migration tests
- [x] Credit purchase, partial funding, payment, refund attribution, and reconciliation tests
- [x] Capability/resource-scope privacy and immediate revocation tests
- [x] Request approval, partial approval, stale decision, and linked audit tests
- [x] Allowance rollover, use-it-or-lose-it, split, recurrence, and duplicate issuance tests
- [x] Capability-protected structured audit export tests
- [x] Swift domain and API-client tests
- [x] Native iOS source type-check against the iOS 17 simulator SDK
- [x] Fresh migration from an empty database through Alembic head
- [x] GitHub Actions server and Swift jobs
- [x] Container image build in GitHub Actions

## Owner acceptance before real financial use

- [ ] Install on the chosen host using `docs/deployment.md`
- [ ] Configure the final DNS name, HTTPS, and unique secrets
- [ ] Create owner, spouse, and child test accounts
- [ ] Confirm each member sees only explicitly granted budgets, accounts, categories, transactions, and reports
- [ ] Submit, partially approve, reject, and cancel delegated funding requests
- [ ] Issue rollover and use-it-or-lose-it allowance plans using test funds
- [ ] Verify a funded card purchase, partial overspending, refund, and payment against a real statement
- [ ] Enter, split, clear, transfer, reconcile, and export sample transactions
- [ ] Create an encrypted backup and restore it into a separate test instance
- [ ] Install the iPhone target on a physical phone with the owner's signing team

The second section depends on the owner's deployment environment and Apple signing identity. Complete it with test data before entering real financial information.
