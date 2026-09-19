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

1. Date/amount mapping options and adapters for OFX/QFX/QIF with bounded, safe parsing.
2. Provider-neutral staged batch/candidate contracts; durable staging must remain money-neutral.
3. Current resource authorization before matching, suggestions, duplicate counts or preview.
4. Stable external identity/fingerprints and bounded canonical-transaction matching. Ambiguous
   candidates remain explicitly reviewable; no silent merge or payee creation.
5. Explicit approval with idempotent canonical transaction commands, concurrent replay protection,
   audit attribution and unchanged reconciliation/transfer/credit-reserve protections.
6. Native mapping/preview/review/history UX, cancellation, partial-error policy and authorized undo.
7. Live/Demo/Local Device adapters through the same application-service boundary, full privacy,
   migration/recovery and financial-observation tests before claiming workflow completion.

Verification: 22 focused parser tests cover quoted/BOM inputs, refunds, currency scales, exact
limits, ambiguous/overflow amounts, malformed dates/records, private-content-safe errors and
10,000-row bounded output. These tests prove parsing only, not authorized posting or full import.
