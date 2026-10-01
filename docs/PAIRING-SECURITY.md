# Secure device pairing foundation

Status: backend, native QR/device management, and Docker automatic-TLS provisioning implemented;
QNAP/Windows guided TLS and real-network human acceptance remain open.

## Trust boundary

Pairing is an authenticated convenience for adding another device to the **same existing user**. It
does not create a household, user, role, grant, or alternative authorization path. The server issues
the same rotating refresh session used by password sign-in, so all budget/resource authorization
continues to be evaluated server-side for that user.

Pairing fails closed unless `BUDGET_APP_PAIRING_PUBLIC_URL` is one canonical HTTPS origin (loopback
HTTP is permitted only for local development). Both code creation and redemption also reject an
ordinary non-loopback HTTP request. Reverse proxies must terminate trusted TLS and pass scheme
information only from a trusted local proxy; the raw API port must never be exposed publicly.

## Protocol

1. An already authenticated device requests `POST /api/v1/auth/pairing-code`.
2. The server invalidates that user's prior unredeemed code and creates 48 random URL-safe bytes.
3. Only SHA-256 of the secret is persisted. The raw code, canonical server origin, and five-minute
   expiry are returned once for local display/QR encoding.
4. A new device submits the code and a bounded device label to `POST /api/v1/auth/pair` over the
   configured secure origin.
5. Atomic one-time redemption consumes the code and creates an ordinary labeled refresh session.
6. Replay, expiry, malformed codes, missing configuration, and insecure transport fail without a
   session. Redemption is additionally subject to the authentication rate limiter.

QR payload construction belongs to the native client so the server never renders third-party QR
content or sends the pairing secret to another service. Passwords, refresh tokens, and financial data
must never appear in a QR payload.

The iOS client encodes a versioned JSON payload containing only the canonical origin and one-time code.
Its scanner independently rejects noncanonical origins and non-loopback HTTP before configuring the
application session. Manual entry remains available when camera access is unavailable or denied. A
successful redemption persists the normal rotating credentials and enters the same Live workspace
route used by password authentication; there is no paired-device-only product hierarchy.

## Device sessions and revocation

`GET /api/v1/auth/sessions` returns only the current user's active refresh sessions. A user may revoke
one of their own session IDs with `DELETE /api/v1/auth/sessions/{id}`; another user's ID has the same
not-found boundary as an unknown ID. Refresh-token rotation preserves the device label. Revocation
prevents further refresh immediately. A previously issued stateless access token can remain valid for
its normal short lifetime (currently at most 30 minutes); immediate access-token invalidation requires
session-bound access-token validation and remains a hardening item.

## Persistence and migration

Revision `0031_pairing_devices` adds nullable labels to existing refresh sessions without changing
their tokens or expiry, plus a separate ephemeral `pairing_codes` table. Downgrade refuses to discard
pairing records or populated device labels. Pairing state is authority-local and is not financial data.
Portable exports exclude it. Operational PostgreSQL and local-device backups retain the table schema
but deliberately omit all pairing-code rows, so restoring an archive can never revive a QR credential.

## Remaining completion gates

- Real-device scan/display, accessibility, revocation, and multi-device human acceptance.
- Consumer server discovery and graphical server installation/configuration.
- Supported automatic TLS/certificate provisioning for QNAP and Windows (Docker is implemented).
- Session-bound access tokens if immediate device revocation is required.
- Abuse, concurrent redemption, proxy-boundary, and real-network integration review.
