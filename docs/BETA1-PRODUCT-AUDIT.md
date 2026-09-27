# Beta 1 product audit

Updated 2026-09-27. Status: IN PROGRESS — not a release-readiness declaration.

Beta 1 supersedes exhaustive roadmap completion as the immediate mission. Deliver a stable,
understandable personal-budgeting experience; preserve advanced engineering without making it
a prerequisite. No feature freeze declared yet.

## First gate: Debt runtime failure

**FIX BEFORE BETA / HUMAN RETEST:** Human Live build `d3f405d` produced competing alert
presentations and eventual code-9 termination. Commit `0b625fe` addresses a reproduced
cancellation-alert path and explicit chart anchors. Four focused production UI tests pass with no
actionable alert/chart warning in the inspected run. This does not establish the code-9 cause or
replace human Live retest.

## Walkthrough record

Do not classify unvisited screens GOOD. Complete this table from actual production-composition
navigation after Debt stabilization, retaining prior human evidence without demanding repeat QA.

| Area | GOOD | FIX BEFORE BETA | CAN WAIT |
|---|---|---|---|
| Home | GOOD: quick actions open canonical transaction/move/schedule editors | Full clean-user financial journey still pending | Advanced dashboard expansion |
| Plan | GOOD: fresh empty state and Create Category Group reachable | Full assign/move journey still pending | Additional advanced planning |
| Activity | Walk pending | Add/edit/search/clear/schedules walkthrough | Further metadata expansion |
| Accounts | GOOD: fresh empty state and Add Account reachable | Starting balance/register/transfer/reconcile journey pending | Advanced debt strategies if unstable |
| Insights | GOOD: friendly hub destinations navigate; chart regression passes | Human Live Debt retest and code-9 cause remain | Additional report types |
| Household | Walk pending | Basic access/settings clarity and privacy | Advanced allowance/delegation expansion |
| Settings | GOOD: profile opens; guided-tour resume moved directly below Profile and regression passes | Appearance/feedback/release build pass pending | Elaborate feedback backend |

## Core acceptance journey

Disposable new user → onboarding → budget → checking/starting balance → categories → assign →
expense → Plan/Activity update → clear → reconcile → schedule → Home/Insights → relaunch/persistence.
Not yet completed in this Beta pass. Human financial data must not be used for destructive tests.

## Deferred: post-beta / Beta 2

- Complete import engine and native import workflow; preserve existing parser/matching/staging code.
- Distant roadmap expansion and exhaustive advanced strategy/household edge workflows.
- Commercial distribution decisions remain explicit external gates, not guessed implementation.

## Verification policy

Focused tests/build/diff per change. Broad suites at Debt stabilization, complete core journey and
release-candidate checkpoints—not after every small UI edit. No test-count target.

## Current delivery constraints

- Branch `codex/development`; no merge/tag.
- Debt fix committed locally as `0b625fe`; its push is pending because GitHub was unreachable.
- Human Live remains unmigrated by this agent. No Simulator reset.
- Xcode Beta 27.0 / 27A5252f; existing iPhone 17 Pro Max / iOS 27,
  `3ABD861E-D38D-4AFD-A356-959266051564`.
