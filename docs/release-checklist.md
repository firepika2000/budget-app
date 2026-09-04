# MVP release checklist

## Automated verification

- [x] Budget authorization and derived-data privacy integration tests
- [x] Ledger, split, transfer, reconciliation, and monthly-summary tests
- [x] Invitation, revocation, rotating-session, and throttling tests
- [x] CSV isolation and formula-injection tests
- [x] Swift domain and API-client tests
- [x] Native iOS source type-check against the iOS 17 simulator SDK
- [x] Fresh migration from an empty database through Alembic head
- [x] GitHub Actions server and Swift jobs
- [x] Container image build in GitHub Actions

## Owner acceptance before real financial use

- [ ] Install on the chosen host using `docs/deployment.md`
- [ ] Configure the final DNS name, HTTPS, and unique secrets
- [ ] Create owner, spouse, and child test accounts
- [ ] Confirm each member sees only explicitly granted budgets
- [ ] Enter, split, clear, transfer, reconcile, and export sample transactions
- [ ] Create an encrypted backup and restore it into a separate test instance
- [ ] Install the iPhone target on a physical phone with the owner's signing team

The second section depends on the owner's deployment environment and Apple signing identity. Complete it with test data before entering real financial information.
