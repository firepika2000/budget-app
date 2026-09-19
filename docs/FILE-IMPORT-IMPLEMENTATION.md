# File import implementation

Status: IN PROGRESS. No user-facing import workflow or posting endpoint exists yet.

## Implemented foundation

`server/app/import_candidates.py` is a side-effect-free CSV adapter. Explicit unique column
mapping selects ISO calendar date, signed decimal amount, payee text and optional memo. UTF-8
with optional BOM, quoted delimiters and quoted multiline fields are supported. Date/locale
guessing, currency conversion and rounding are deliberately absent: later mapping UI must make
these choices explicit rather than silently changing financial meaning.

Currency scale is an explicit input; an eventual application service must supply the authoritative
budget scale, not trust a client-supplied override. Integer arithmetic checks signed Int64 bounds.
Current server budget schemas store a currency code but no shared scale resolver was found in
the money/schema audit. Establish and test that contract before exposing import posting; do not
default every currency to two decimals or derive financial truth from display formatting.
Candidates retain source record numbers and descriptive text, not database payee identities.
No payee resolution/creation or transaction posting occurs during parsing.

Limits: 10 MiB input, 10,000 records, 100 columns, 4,096 characters per field, 150-character payee
and 500-character memo. All rows must validate before a result is returned. Errors name positions
or constraints, never file contents. CSV formula-like descriptive text is data, never executed;
any later spreadsheet export still requires its own formula-injection defenses.

## Required next dependencies

1. Further date/amount mapping options and adapters for OFX/QFX/QIF with bounded, safe parsing.
2. Provider-neutral staged batch/candidate contracts; durable staging must remain money-neutral.
3. Current resource authorization before matching, suggestions, duplicate counts or preview.
4. Stable external identity/fingerprints and bounded canonical-transaction matching. Ambiguous
   candidates remain explicitly reviewable; no silent merge or payee creation.
5. Explicit approval with idempotent canonical transaction commands, concurrent replay protection,
   audit attribution and unchanged reconciliation/transfer/credit-reserve protections.
   `budgeting_routes.create_transaction_in_session` now owns authorization, payee resolution,
   reserve events and audit without committing; the existing HTTP route commits the returned
   transaction. Reuse this operation with deliberate caller commit/rollback rather than copying
   accounting logic or looping auto-committing routes. Durable idempotency and approval remain open.
6. Native mapping/preview/review/history UX, cancellation, partial-error policy and authorized undo.
7. Live/Demo/Local Device adapters through the same application-service boundary, full privacy,
   migration/recovery and financial-observation tests before claiming workflow completion.

Verification: 22 focused parser tests cover quoted/BOM inputs, refunds, currency scales, exact
limits, ambiguous/overflow amounts, malformed dates/records, private-content-safe errors and
10,000-row bounded output. These tests prove parsing only, not authorized posting or full import.

### Explicit bank CSV mapping

After `61f029c`, mapping supports comma, semicolon or tab separators; ISO yyyy-mm-dd or explicitly
selected m/d/yyyy and d/m/yyyy dates; and either one signed amount or separate debit/credit columns.
No date-order sniffing occurs. Split amount columns must be nonnegative and cannot both be nonzero;
blank plus a valid opposite column is supported, while both blank is invalid. Debit subtracts and
credit adds using exact integer arithmetic. Unsupported separators, conflicting column modes,
negative debit/credit values, invalid leap dates and overprecision fail before returning candidates.
Thirty-five focused tests cover these contracts. Grouping separators, decimal-comma amounts and
additional date formats remain explicit mapping work, not silently guessed behavior.

### Canonical creation transaction boundary

After `8a72030`, the HTTP route delegates to a caller-controlled unit of work. Request DTOs are
deep-copied before identity resolution so retry input is not mutated. A regression creates a
transaction, fails a second operation and rolls back: transaction, payee and audit counts must
return to baseline. It also proves two successful operations can commit together and share one
payee. Existing accounting tests continue exercising the same canonical code through HTTP.

The rollback regression initially failed because sqlite3 legacy mode released a payee savepoint
before an outer database transaction began. The resolver now explicitly begins only when the
SQLite driver reports no active transaction; PostgreSQL is untouched. This behavior is documented
by [SQLAlchemy's SQLite transaction guidance](https://docs.sqlalchemy.org/en/20/dialects/sqlite.html).
This does not claim the complete import approval/concurrency workflow is implemented.
