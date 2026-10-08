# File import implementation

Status: IN PROGRESS. The authenticated server API exposes money-neutral statement staging,
duplicate review, reload, cancellation, explicit approval, and atomic approved-import undo for CSV/TSV/delimited text,
OFX/QFX, QIF, SWIFT MT940, ISO 20022 CAMT XML, and conservatively recognized text-based PDF statements. The native reconciliation
UI is active for Budget Server workspaces and only explicit approval can post ledger rows. Local
on iPhone now supports CSV, TSV, explicitly delimited text, structured OFX/QFX, QIF, MT940, CAMT, and
conservatively recognized text-based PDFs through the same review UI.

Local Device import review/history is durable in the Local Device SQLite authority rather than being
session-only. Review, approved, cancelled and undo metadata survives app/repository relaunch, remains
account-scoped, and participates automatically in the existing encrypted database backup/restore path.

Local Device duplicate suggestions now use only currently visible, posted observations from the
selected statement account. Exact and possible matches are deterministically ordered, capped at 20
each, and report truncation. A same-date/amount/payee transaction in another account, or a voided
transaction in the selected account, cannot incorrectly steer review toward skipping a legitimate row.
Exact matching is also first-class-payee alias aware for owners and otherwise unrestricted actors in
both Budget Server and Local Device modes. Resource-scoped members receive no alias observations, so
statement review cannot reveal private household aliases through exact-match suggestions.

The native review now treats cancellation as an explicit lifecycle operation. Before preview,
Close simply leaves the file picker flow because no server state exists. After staging, Cancel
Import requires confirmation and calls the provider's optimistic-version cancellation contract;
it does not post or delete transactions. Live, Demo, and Local Device providers share this command
surface, and stale/replayed cancellation is rejected.

Statement Import History is available from reconciliation. It uses a bounded, paginated metadata
endpoint scoped to the current actor and account; imported payee/memo text is not included in list
responses. Opening one item performs a fresh authorization check before loading private candidate
details. Review batches resume with the same duplicate-safe defaults, while approved and cancelled
batches remain inspectable and read-only.

Current endpoints:

- `POST /api/v1/budgets/{budget}/accounts/{account}/statement-imports`
- `GET /api/v1/budgets/{budget}/accounts/{account}/statement-imports/{batch}`
- `POST /api/v1/budgets/{budget}/accounts/{account}/statement-imports/{batch}/cancel`
- `POST /api/v1/budgets/{budget}/accounts/{account}/statement-imports/{batch}/approve`
- `POST /api/v1/budgets/{budget}/accounts/{account}/statement-imports/{batch}/undo`

Uploads use a bounded raw body and explicit format/currency/mapping headers. CSV column and
date-order selection is never guessed. Structured formats normalize through the same owned
staging boundary. Responses contain authorized, bounded duplicate suggestions.
Approval requires a `post` or `skip` decision for every source row, atomically claims the review
version before writing, and sends selected rows through canonical transaction creation. Any failed
row rolls back the entire claim and write set; a concurrent or replayed approval returns 409.

## Implemented foundation

`server/app/import_candidates.py` is a side-effect-free CSV adapter. Explicit unique column
mapping selects ISO calendar date, signed decimal amount, payee text and optional memo. UTF-8
with optional BOM and explicitly BOM-marked UTF-16 little/big endian, quoted delimiters and quoted
multiline fields are supported. Unmarked UTF-16 remains rejected rather than guessing an encoding. Date/locale
guessing, currency conversion and rounding are deliberately absent: later mapping UI must make
these choices explicit rather than silently changing financial meaning.

Currency scale is an explicit input; an eventual application service must supply the authoritative
budget scale, not trust a client-supplied override. Integer arithmetic checks signed Int64 bounds.
The authenticated staging route resolves the ISO 4217 minor-unit exponent at the server boundary;
clients cannot select a decimal scale. This contract must also be reused by eventual approval.
Candidates retain source record numbers and descriptive text, not database payee identities.
No payee resolution/creation or transaction posting occurs during parsing.

Limits: 10 MiB input, 10,000 records, 100 columns, 4,096 characters per field, 150-character payee
and 500-character memo. All rows must validate before a result is returned. Errors name positions
or constraints, never file contents. CSV formula-like descriptive text is data, never executed;
any later spreadsheet export still requires its own formula-injection defenses.

## Required next dependencies

1. Additional bank-specific PDF mapping profiles and optional local OCR. Arbitrary PDF layout is
   not trusted as structured financial data. The current extractor accepts only unencrypted,
   text-based statements whose transaction lines begin with an explicit date and end in a signed
   or parenthesized amount. Unsigned values, balances, headers and totals are ignored; unsupported
   or scanned statements fail clearly rather than silently inventing transactions.
2. Provider-neutral staged batch/candidate contracts; durable staging must remain money-neutral.
3. Current resource authorization before matching, suggestions, duplicate counts or preview.
4. Stable external identity/fingerprints and bounded canonical-transaction matching. Ambiguous
   candidates remain explicitly reviewable; no silent merge or payee creation.
5. Explicit approval has PostgreSQL concurrency coverage: two genuinely overlapping approvals of
   one reviewed batch produce one canonical cleared transaction and one `409` conflict. Canonical
   transaction commands, optimistic replay protection, audit attribution and unchanged
   reconciliation/credit-reserve protections remain active.
   `budgeting_routes.create_transaction_in_session` now owns authorization, payee resolution,
   reserve events and audit without committing; the existing HTTP route commits the returned
   transaction. Approval reuses this operation inside one caller-owned transaction.
6. Partial-error policy. Native bounded history/reopen, cancellation, and authorized undo are now
   production-wired across Live, Demo, and Local Device providers. Undo row-locks the approved batch,
   rechecks optimistic version and current account scope, prevalidates every posted transaction, and
   applies the canonical void/reversal operation to all rows in one database transaction. A
   reconciled, stale, missing, or otherwise ineligible row rejects the entire request without a
   partial undo. Reversal identities are retained in the staged candidate metadata, so the operation
   remains inspectable and replay-safe without adding another financial source of truth.
7. The production reconciliation sheet now provides file selection, explicit CSV mapping,
   duplicate-aware preview, category selection and all-row post/skip approval through the shared
   workspace command contract. The Budget Server adapter is active for every listed format. The
   Local-on-iPhone adapter now stages and posts CSV/TSV/delimited text, OFX/QFX, QIF, MT940, and CAMT using
   exact minor units, local duplicate suggestions and canonical transaction creation. OFX/QFX
   accepts bounded OFX 1.x SGML and OFX 2.x XML-style transaction records while rejecting entity
   and document-type declarations. QIF uses the same explicit date-order, strict grouped-amount,
   deterministic two-digit-year, bounded-input and private-safe validation rules as Budget Server.
   Its PDFKit adapter applies the same conservative signed-row contract as Budget Server and fails
   closed for scanned, encrypted, unsigned-only, or ambiguous statements.
   Live and Local Device now both retain bounded history across relaunch. Continue full privacy,
   recovery and financial-observation testing before claiming workflow completion.

Verification: 22 focused parser tests cover quoted/BOM inputs, refunds, currency scales, exact
limits, ambiguous/overflow amounts, malformed dates/records, private-content-safe errors and
10,000-row bounded output. These tests prove parsing only, not authorized posting or full import.

### OFX/QFX and QIF adapters

`import_formats.py` adds bounded OFX/QFX and QIF adapters. Both produce the same money-neutral
`ImportCandidate` records as CSV and preserve exact integer minor units. OFX 1.x SGML and OFX 2.x
XML-style transaction records are supported without invoking an XML entity resolver; document type
and entity declarations are refused. Posted timestamps retain the institution-provided calendar
date rather than applying a device timezone. QIF requires an explicit m/d/y or d/m/y selection and
never guesses locale. Common grouped QIF amounts are normalized only after strict validation.

Both adapters enforce the shared 10 MiB / 10,000-row / bounded-description limits, use private-text-
safe validation errors and perform no matching, payee creation, clearing, reconciliation or posting.
PDF extraction remains review-only because layout is not a reliable financial contract. Every
recognized row is returned for explicit post/skip review; nothing is silently approved.

### MT940 adapter

SWIFT MT940 `.sta`, `.mt940`, and `.940` exports use the same money-neutral review boundary in
Budget Server and Local Device modes. The adapter accepts bounded `:61:` transaction records,
uses their fixed YYMMDD calendar date and debit/credit mark, converts the standard decimal-comma
amount directly to exact minor units, and treats an optional `:86:` record plus continuation lines
as descriptive text. Opening/closing balances and other statement metadata are ignored rather than
misclassified as transactions. Malformed transaction-looking records, zero amounts, excessive
precision, invalid dates, oversized files, excessive rows, and overlong descriptions fail closed
with private-text-safe errors. No row posts until the existing duplicate-aware review is approved.

### ISO 20022 CAMT adapter

CAMT.052, CAMT.053 and CAMT.054 XML exports are accepted as `.camt` or `.xml` files in Budget
Server and Local Device modes. Only `Ntry` statement entries become candidates. Debit/credit
direction, booking date (or value-date fallback), exact decimal amount, counterparty name and
remittance information flow into the existing money-neutral review. The parser rejects document
type and entity declarations, malformed dates/directions/amounts, zero values, oversized input,
more than 10,000 entries and overlong descriptions without echoing private source data. Balance
and statement metadata are not posted, and every candidate still requires explicit approval.

### Explicit bank CSV mapping

After `61f029c`, mapping supports comma, semicolon or tab separators; ISO yyyy-mm-dd or explicitly
selected m/d/yyyy and d/m/yyyy dates; and either one signed amount or separate debit/credit columns.
No date-order sniffing occurs. Split amount columns must be nonnegative and cannot both be nonzero;
blank plus a valid opposite column is supported, while both blank is invalid. Debit subtracts and
credit adds using exact integer arithmetic. Unsupported separators, conflicting column modes,
negative debit/credit values, invalid leap dates and overprecision fail before returning candidates.
Thirty-five focused tests cover these contracts. The production mapper now additionally requires an
explicit number convention: `1,234.56` or `1.234,56`. Correctly grouped thousands are normalized
before exact integer-minor-unit conversion in both Budget Server and Local Device modes. Mixed
conventions and malformed grouping fail without echoing private statement content. The choice is
transmitted independently of the CSV field separator, so semicolon-delimited decimal-comma exports
do not require locale guessing.

The explicit date-order selector accepts the common slash, dash, or dot separators used by bank
exports (`YYYY/MM/DD`, `MM-DD-YYYY`, and `DD.MM.YYYY`, for example) while requiring one consistent
separator and a four-digit year. It never guesses whether the first component is month or day.

The native picker exposes the same field-separator contract for `.csv`, `.tsv`, and `.txt` bank exports.
TSV defaults to a tab separator; CSV and text default to comma. The user can change it explicitly,
which rebuilds the header mapping rather than sending mismatched column names to the server.

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

Additional funded-card verification after `2e9f532`: a funded card purchase creates real reserve
events inside the caller-owned unit, then a later invalid-category operation fails. Rollback must
restore transaction/payee/audit/reserve counts, the complete month summary and posted register
exactly. Thirteen unit-of-work/card tests PASS. This strengthens atomic approval prerequisites;
durable batch identity, concurrency, matching and user approval are still not implemented.

### Matching foundation after `8de36b5`

`import_matching.py` produces review suggestions only. Same exact signed amount/date/normalized
payee yields an exact suggestion, never automatic approval. Same amount in an explicitly selected
zero-to-seven-day window yields possible suggestions. Debit and refund directions remain distinct.
Name normalization reuses the canonical payee normalization. Authorized adapters may also supply
first-class-payee aliases; the production adapter does so only for unrestricted actors and the local
adapter follows the same rule. Repeated identical candidate date/amount/name/memo flags the first source record;
neither candidate is discarded because identical legitimate purchases can exist.

Inputs are capped at 10,000 candidates and 50,000 observations. Amount/date/name indexes avoid
candidate-by-history scanning; each indexed bucket retains 20 IDs and count information. Output
has at most 20 exact plus 20 possible IDs per candidate and an explicit truncation flag. Ordering
is deterministic by date distance, prior before following date, then ID. Forty import tests PASS,
including the full 10,000-by-50,000 repeated-data case.

This module has no database access or security authority. Before exposing it, an application
service MUST select only currently authorized observations for the chosen budget/account, before
indexing/counting/ranking. That service must also recheck authority during approval. No API currently
exposes this matcher, and no complete authorization/matching workflow is claimed. Durable staging,
external IDs, pagination/refinement for truncated matches, transfer matching and approval remain open.

### Authorized observation retrieval after `04dfefa`

`import_review.load_match_observations` checks current view/create transaction capabilities, target
account visibility and budget ownership, then applies the same SQL account/category/split predicate
as the production transaction browser before retrieving scalar observations. Only posted rows in
the selected account/date range are returned. At most 50,001 rows are read; the extra row causes an
explicit narrow-range error rather than silently incomplete matching. No payees/splits/attachments
are hydrated for matching. No HTTP endpoint exposes this service yet.

Fourteen focused review/browser/matcher tests PASS. Review regression excludes hidden-category
transactions, uncategorized salary and mixed-visible/private splits before producing observations;
it also checks date filtering and hidden/missing account denial. Current capability checks happen
on every invocation, but approval must independently recheck them. Durable staging, integration,
format coverage, approval/replay and native UX remain required.

### Durable staging schema after `69bdd0d`

Revision `0030_import_staging`, following `0029_cash_rollover_history`, adds `import_batches`:
budget/account/actor ownership, review/approved/cancelled status, optimistic version, bounded
candidate count, normalized candidate JSON, source format and creation timestamp. It does not
store original uploaded files or write financial tables. Service validation must enforce candidate
shape/count consistency, account-budget ownership and current authority; table fields alone are
not a security boundary. No staging creation or approval endpoint is exposed yet.

Downgrade refuses populated staging to avoid silently losing review/history. Empty staging can
be downgraded. Populated PostgreSQL upgrade proof compares every preexisting table and financial
month observation, then inserts money-neutral staging and verifies populated downgrade refusal.
Human Live remains `0020_payee_identity_repair`; this migration is tested only on disposable data.

### Staging lifecycle service after `2983d3e`

`import_staging` accepts validated normalized candidates through an internal application service,
not an HTTP file-upload endpoint. It requires current view/create transaction authority, an open
visible account in the budget, exact matching currency code, known source format and 1...10,000
well-formed unique source rows with Int64 amounts. Parsing adapters must still establish the
authoritative decimal scale before producing minor units; this service does not accept a scale.

Persistence is caller-owned commit/rollback. Retrieval first resolves owner/budget/account metadata,
rechecks current permissions, then hydrates candidate text. Even other household managers cannot
read another actor's unapproved import file data by guessing its batch ID. Cancellation uses a
conditional status/version update; stale/repeated cancellation returns conflict without posting.
Review data is retained, not destructively deleted. Approval, replay protection and cancellation
concurrency on PostgreSQL remain additional verification/implementation work.

Six focused staging/review tests PASS: reopen persistence, owner isolation, account-scope revocation,
cancel/version conflict, malformed/overflow/currency refusal and unchanged financial observations.
