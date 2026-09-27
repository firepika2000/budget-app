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
| Plan | GOOD: fresh group/category creation and exact assignment editing pass in production composition | Move-money journey still pending | Additional advanced planning |
| Activity | GOOD: shared clear/unclear interaction and scheduled realization pass | Add/edit/search walkthrough still pending | Further metadata expansion |
| Accounts | GOOD: fresh account creation, starting balance, metadata edit, register clearing and reconciliation lockout pass | Transfer journey still pending | Advanced debt strategies if unstable |
| Insights | GOOD: friendly hub destinations navigate; chart regression passes | Human Live Debt retest and code-9 cause remain | Additional report types |
| Household | Walk pending | Basic access/settings clarity and privacy | Advanced allowance/delegation expansion |
| Settings | GOOD: profile opens; guided-tour resume moved directly below Profile and regression passes | Appearance/feedback/release build pass pending | Elaborate feedback backend |

Authentication fields now advertise native username/current-password/new-password, name,
household and invitation-code semantics for Password AutoFill and appropriate keyboard behavior.

## Core acceptance journey

Disposable new user → onboarding → budget → checking/starting balance → categories → assign →
expense → Plan/Activity update → clear → reconcile → schedule → Home/Insights → relaunch/persistence.
Not yet completed in this Beta pass. Human financial data must not be used for destructive tests.

## Deferred: post-beta / Beta 2

- Complete import engine and native import workflow; preserve existing parser/matching/staging code.
- Distant roadmap expansion and exhaustive advanced strategy/household edge workflows.
- Commercial distribution decisions remain explicit external gates, not guessed implementation.

## Beta presentation

- Added an original production AppIcon asset; the Release build now emits compiled icon variants
  instead of installing with the iOS placeholder grid.
- Profile & Settings exposes the installed version/build and a native share action for a deliberately
  privacy-safe diagnostic summary (version, provider and connection state; no financial data).
- Added the app privacy manifest required for app-local `UserDefaults` preferences (`CA92.1`), with
  tracking disabled, no tracking domains and no developer-collected data declared. The XcodeGen
  source also retains the existing camera-purpose string so project regeneration cannot drop it.
- Release-configuration Xcode Beta simulator build passes with the asset catalog compiled.
- The Release build installs and launches on the existing Simulator without clearing its data; the
  icon renders on the Home Screen and the prior Live-provider/authentication route remains intact.
- App Store metadata, screenshots, privacy declarations and signing/archive validation remain a
  later release-candidate checkpoint.

## Verification policy

Focused tests/build/diff per change. Broad suites at Debt stabilization, complete core journey and
release-candidate checkpoints—not after every small UI edit. No test-count target.

## Current delivery constraints

- Branch `codex/development`; no merge/tag.
- Local Beta checkpoints `0b625fe` and `a536712` are pending push because GitHub is unreachable.
- Human Live remains unmigrated by this agent. No Simulator reset.
- Xcode Beta 27.0 / 27A5252f; existing iPhone 17 Pro Max / iOS 27,
  `3ABD861E-D38D-4AFD-A356-959266051564`.
- The concise launch gate and remaining human flow are maintained in
  [BETA1-RELEASE-CHECKLIST.md](BETA1-RELEASE-CHECKLIST.md).
