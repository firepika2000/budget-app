# Local-first TestFlight checkpoint

The next TestFlight revision changes the normal first launch from server setup to an authoritative
budget stored privately on the iPhone. A new user enters the same production workspace used by
server-backed budgets; no example fixtures, server, account, or sign-in are required.

## Product behavior

- **On This iPhone** is the fresh-install default and works without connectivity.
- Accounts, category groups/categories, exact minor-unit transactions and splits, allocations,
  reconciliation observations, targets, favorites, payees/aliases, schedules, debt terms, rollover
  policy history, and encrypted attachment metadata/content survive process termination.
- The example household remains available only under the explicitly labeled **Training** section.
- Profile & Settings identifies the current authority and owns the Data Location / future transfer
  surface. Connecting to an existing server does not delete the local copy. Automated migration of
  a local budget into a server is intentionally not claimed by this revision.
- Local personal mode exposes only the device owner. Invitations, delegated budgets, requests, and
  allowances remain server-household capabilities rather than simulated local features.

## Offline boundary

On-device mode is fully offline because the phone database is authoritative; changes do not wait
for network synchronization. A future server-backed offline outbox will cache authorized reads and
queue only operations with defined idempotency/conflict rules. This revision does not silently queue
allocation or reconciliation commands against an unreachable shared authority.

## Storage boundary

The authority is a private, migrated SQLite database in Application Support. Attachments use the
same application-service workflow and are encrypted separately with a key stored through the device
keychain boundary. Complete workspace publication is transactional. If durable storage cannot open,
the workspace fails closed instead of accepting changes into volatile memory.

## TestFlight acceptance

1. Delete the previous beta app only if intentionally testing a true fresh install; deletion removes
   local-only data, as expected for this checkpoint.
2. Install the new build and launch with airplane mode enabled.
3. Confirm the Home/Plan/Activity/Accounts/Insights shell opens without server setup or sign-in.
4. Create an account, category group/category, assignment, and transaction.
5. Force-quit and relaunch while still offline; confirm balances, Plan, and Activity agree.
6. Open Profile & Settings and confirm **On This iPhone** plus **Server & Transfer Options**.
7. Confirm the example budget appears only after explicitly choosing **Open Example Budget** under
   Training, and that returning to On This iPhone restores the real local budget.

