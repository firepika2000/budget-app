# Live-Server Bootstrap and Authentication (v0.4 development/live acceptance)

> Scope: this document describes the authentication and first-run bootstrap flow required to
> take a fresh self-hosted Budget Server from "just started" to "an authenticated owner is using
> the live app" during v0.4 human acceptance. It is deliberately **not** the v0.9 consumer
> onboarding system. Local network discovery, named-server pairing, QR pairing, and secure remote
> access remain future work per [ROADMAP.md](ROADMAP.md) (Device Pairing and Networking). Raw
> server-address entry stays acceptable for this development gate only.

The target end-to-end path is:

```
Fresh local server → connect from iOS → create or sign in a user → establish household context → enter the live app
```

using ordinary application UI and supported server APIs, with no universal default password, no
hard-coded credentials, and no anonymous owner access.

## 1. Server-state discovery contract

The client must not have to *guess* server state by interpreting authentication failures (a `401`
on a fresh, unconfigured server is indistinguishable from a wrong password). An explicit,
unauthenticated discovery endpoint reports just enough for the client to choose the right screen.

`GET /api/v1/bootstrap/status` → `200 OK`

```json
{
  "initialized": false,
  "authentication_required": true,
  "api_version": "0.4.0"
}
```

| Field                     | Meaning                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------- |
| `initialized`             | `true` once a first owner exists; `false` while the server is still openly claimable.   |
| `authentication_required` | Always `true` for this deployment model — the client always needs a session to proceed. |
| `api_version`             | Server API version, for a client-side compatibility check.                              |

**Deliberately omitted.** The response exposes no usernames, emails, household names, member
counts, database details, tokens, secrets, or password-policy internals. `initialized` is a single
boolean derived from existence, not from any identifying record. A regression test asserts the
response keys are exactly `{initialized, authentication_required, api_version}` and that the owner
email/household/display name never appear in the body.

**No authentication required.** Discovery necessarily precedes sign-in, so the endpoint takes no
`Authorization` header and returns the same shape to any caller.

`initialized` is computed defensively as "a setup claim row exists **or** any user exists". The
second clause means a database created before the atomic-claim mechanism (users present, no
`SetupState` row) is still correctly reported as initialized, so an existing installation never
re-enters first-run setup.

## 2. First-owner bootstrap security model

`POST /api/v1/auth/bootstrap` creates the first owner + household and is the **only** endpoint that
can do so. Its security properties:

- **Single-use, atomic claim.** The first statement inserts `SetupState(id=1)` — a unique primary
  key. Two concurrent bootstraps both attempt the same insert; exactly one commits and the other
  raises `IntegrityError`, which is translated to `409 Conflict` ("Server is already configured").
  The database, not application-level checking, is the arbiter, so the race cannot produce two
  initial owners.
- **Disabled after initialization.** Once claimed, every later bootstrap attempt — from any device —
  returns `409`. A second device cannot re-run first-owner bootstrap.
- **Real credentials only.** The password is hashed with the existing `hash_password` mechanism
  (the same one `login` verifies against). There is no default password and no bypass for local
  servers.
- **Complete owner context in one transaction.** The owner `User`, the `Household`
  (`owner_user_id`), and the `Membership` with the `OWNER` role are created together, then a session
  is issued. A failure rolls the whole thing back rather than leaving a half-initialized server.

Subsequent members never use bootstrap; they join through the invitation/accept flow
(`POST /api/v1/auth/accept-invitation`), which is unaffected by the setup claim.

### Tested behaviors (backend)

`server/tests/test_auth.py`:

- discovery reports uninitialized on a fresh server, with the exact safe key set;
- discovery flips to initialized after the first owner and *stays* claimed;
- a second bootstrap after initialization returns `409` (second-device claim rejected);
- discovery leaks none of the owner email / household / display name;
- discovery requires no authentication;
- first bootstrap succeeds (`201`) and is single-use;
- login success issues a working bearer token + refresh token; wrong password and missing token are
  rejected; repeated failures are rate-limited (`429` with `retry-after`);
- refresh rotates and reuse revokes; logout revokes the refresh token.

True concurrent-bootstrap racing under PostgreSQL is covered by the concurrency suite documented in
[postgres-concurrency-testing.md](postgres-concurrency-testing.md); the unique-PK claim above is the
mechanism those tests exercise for the single-owner guarantee.

## 3. iOS authentication state machine

`AppSession.configureServer` drives a small, explicit state machine
(`ServerConnectionStatus`), and `RootView` renders one screen per state:

| Server condition                         | `ServerConnectionStatus`    | Screen shown                              |
| ---------------------------------------- | --------------------------- | ----------------------------------------- |
| Cannot be reached / bad address          | `.unreachable` / `.invalidConfiguration` | Connection screen with an understandable failure message |
| Reachable, `initialized == false`        | `.setupRequired`            | **First-Time Setup** (create owner)       |
| Reachable, initialized, no valid session | `.authenticationRequired`   | **Sign In**                               |
| Reachable, initialized, session present  | `.connected`                | Budgets list, with identity + **Sign out** |

Flow: after a successful `GET /health`, the client calls `bootstrapStatus()`. If the server reports
uninitialized, it routes to First-Time Setup (`AuthenticationView(firstRun: true)`), which presents
the owner-creation fields and the title "First-Time Setup" rather than a Sign In prompt a tester
cannot satisfy. Otherwise it shows Sign In, or goes straight to the app when a session already
exists. A server that predates the discovery endpoint fails the `bootstrapStatus()` call softly
(`try?`) and falls back to the prior Sign In / connected behavior.

**No silent downgrade.** Authentication or reachability failures move to
`.authenticationRequired`, `.unreachable`, or `.invalidConfiguration` — never silently to the
deterministic demo. Deterministic demo is only ever entered by an explicit user choice, and the demo
and live sources stay isolated (`AppDataSourceMode`).

## 4. Credential storage and server scoping

- Tokens are stored with `KeychainStore` (`kSecClassGenericPassword`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) under fixed accounts (`access-token`,
  `refresh-token`). The endpoint URL lives in ordinary `UserDefaults` configuration, not the
  Keychain.
- **Cross-server token reuse is prevented.** When the configured server URL changes,
  `configureServer` clears the stored credentials and best-effort revokes the old refresh session
  against the previous server before adopting the new one. A token minted by server A is therefore
  never presented to server B.
- Access tokens are short-lived JWTs; refresh happens transparently (`refreshIfNeeded`) with a
  safety margin before expiry. Sign out revokes the refresh session server-side and clears local
  credentials.
- **Never logged.** Passwords, JWTs, refresh tokens, and `Authorization` headers are never written
  to logs; debug logging records only coarse categories (e.g. `http-409`, `network-…`).

## 5. Acceptance scenarios

### Fresh database

1. Start a new server (empty database). `GET /api/v1/bootstrap/status` → `initialized: false`.
2. Connect from iOS → the app shows **First-Time Setup**.
3. Create the owner (email, name, household, password) → owner + household + OWNER membership created
   atomically, session issued, app enters the Budgets list as the authenticated owner.
4. `GET /api/v1/bootstrap/status` now → `initialized: true`.

### Existing database

1. Server already has an owner. `GET /api/v1/bootstrap/status` → `initialized: true`.
2. Connect from iOS → the app shows **Sign In** (not setup).
3. Correct credentials → authenticated and into the live app; wrong credentials → a clear error,
   still on Sign In, with no downgrade to demo.

### A second device cannot re-run first-owner bootstrap

1. Owner already established on device A.
2. Device B connects → discovery reports `initialized: true` → **Sign In**, not setup.
3. If device B calls `POST /api/v1/auth/bootstrap` directly anyway → `409 Conflict`. Ownership
   cannot be re-claimed.

### Pre-atomic-claim database

An installation whose users predate the `SetupState` claim row (users exist, no claim row) is still
reported `initialized: true` by the existence check, so it presents Sign In and never re-runs setup.

## 6. Validation status

- **Backend:** the auth/bootstrap/discovery suite passes on the development host. Two unrelated
  failures are environmental and predate this work: the Windows-only dev-launcher tests (a POSIX
  shell script that cannot exec under Windows; they pass on macOS/Linux) and one date-sensitive
  forecast test in `test_planning.py` (hard-coded dates). Neither is a regression from this change.
- **Swift client:** `Tests/BudgetAPITests/APIClientTests.swift` covers `bootstrapStatus()` decoding,
  the discovery path, and the absence of an `Authorization` header, alongside the existing client
  contract tests.
- **iOS UI / simulator:** the SwiftUI routing (`RootView`, `AppSession`) is implemented, but native
  build and simulator/UI-test validation require a macOS + Xcode toolchain and are **pending** on
  that environment; they were not run on the Windows development host, and no native validation is
  claimed here.
