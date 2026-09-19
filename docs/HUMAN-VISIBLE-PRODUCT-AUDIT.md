# Human-visible product audit — stabilization gate

Status: IN PROGRESS. Human Live Debt failure blocks feature expansion. This initial inventory is
not a completed screen-by-screen runtime audit. Source presence and old tests do not establish
current visible quality. UNVERIFIED means a new production-composition walkthrough is still owed.

Priority: P0 crash/data-loss/security/accounting; P1 broken primary workflow; P2 severe UX or
discoverability; P3 missing user-facing functionality; P4 backend/architecture enhancement.

| Surface | Current classification / evidence | Required next action |
|---|---|---|
| Home | UNVERIFIED in this stabilization pass | Walk loading/empty/populated/navigation |
| Plan | UNVERIFIED | Walk groups/categories/favorites/funding/targets |
| Activity | UNVERIFIED | Walk search/edit/clear/bulk/history |
| Accounts | UNVERIFIED | Walk empty/add/register/transfer |
| Insights / Debt | BROKEN — human Live P0; Demo success/error tests pass | Reproduce actual loop; do not overrule human result |
| Other Insights charts | UNVERIFIED; human axis warning | Walk all charts and inspect runtime warnings |
| Forecast | UNVERIFIED | Verify actual vs projected and discoverability |
| Scheduled Transactions | UNVERIFIED | Walk active/paused/edit/realize |
| Household | UNVERIFIED | Walk access/invitations/member navigation |
| Requests / Allowances | UNVERIFIED | Walk role-specific creation/approval/lifecycle |
| Profile & Settings | UNVERIFIED | Walk switching, privacy, appearance, account context |
| Payees | UNVERIFIED | Search, create/rename/merge/archive/discoverability |
| Debt Terms | UNVERIFIED in Live failure context | Shared editor, sheet ownership, save/recalculate |
| Attachments | UNVERIFIED | Source picker, preview, remove confirmation, permissions |
| Reconciliation | UNVERIFIED in this pass; prior human evidence retained | Review existing evidence before requesting repeat QA |
| Import | BACKEND EXISTS BUT UI MISSING; backend also incomplete | Keep paused until stabilization gates pass |

## Backend-to-UI inventory (completion not inferred)

| Feature | Backend / API / UI evidence so far | Discoverability / coverage / acceptance | Next action |
|---|---|---|---|
| Debt Intelligence | Projection/report services and production UI exist | Success UI test passes; Live human FAIL | P0 investigation |
| Insights restructuring | Focused report destinations exist | Complete walkthrough pending | Runtime/chart audit |
| Appearance | Existing preferences implementation | Current runtime/acceptance reconciliation pending | Light/dark/system walkthrough |
| Category favorites | Existing canonical service/UI actions | Current discoverability unverified | Plan audit |
| Hide Amounts | Workspace privacy overlay/state exists | Chart/VoiceOver completeness unverified | Privacy audit |
| Household access | Backend and production views exist | Complete current role matrix UI audit pending | Restricted/owner walkthrough |
| Requests/allowances | Existing service and views | Current discoverability/acceptance reconciliation pending | Lifecycle walkthrough |
| Onboarding | Existing guided onboarding | Current empty Live composition unverified | Fresh disposable household |
| Payee management | Search and management views exist | Prior evidence must be reconciled | Search/management walkthrough |
| Attachments | Existing provider/service/native workflow | Prior human evidence retained, not blanket acceptance | Presentation audit |
| Audit/history | Transaction audit/backend exists | User-visible coverage inventory incomplete | Trace each history destination |
| Import | Parsers/matching/staging foundations only; Swift API/native UI absent | Not discoverable; no end-to-end UI/human acceptance | Resume vertical integration only after P0/P1 closure |

For each row, the completed audit must explicitly resolve backend, Swift API and native UI
completion separately; record discoverability, automated UI tests, actual human evidence and next
action. Do not label unvisited screens WORKING or infer HUMAN PASS from automated tests.
