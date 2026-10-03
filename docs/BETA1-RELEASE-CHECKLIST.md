# Beta 1 TestFlight release checklist

Updated 2026-09-30. This is the short launch gate for the first closed TestFlight build.
It does not replace the product audit or broader production-readiness history.

## Engineering gate

- [x] Production AppIcon is bundled and compiled into device and Simulator builds.
- [x] `PrivacyInfo.xcprivacy` is bundled and declares app-local `UserDefaults` use (`CA92.1`).
- [x] Camera and local-network purpose strings are present in the archived app.
- [x] A structured privacy-safe Beta feedback template can be shared from Profile & Settings.
- [x] Unsigned arm64 generic-device archive succeeds with Xcode 27 Beta.
- [x] Release configuration installs and launches on the preserved iPhone 17 Pro Max / iOS 27
  Simulator; the production icon renders and existing provider/authentication state survives install.
- [x] Focused production UI checks pass for onboarding, fresh account/category setup,
  assignment editing, clearing/reconciliation, scheduling, Home, Insights and Debt failure handling.
- [x] Previously authorized server workspaces open from a protected snapshot during temporary
  outages; ordinary transaction entry queues durably and replays exactly once after reconnect.
- [x] Transient refresh failures use a compact workspace status instead of replacing the current
  route or presenting a blocking alert.
- [ ] Human Live retest confirms Debt navigation no longer repeats alerts or terminates.
- [ ] One disposable Live user completes the concise core journey and relaunch persistence check.
- [x] Release-candidate backend, migration, Swift, native XCTest, focused XCUITest, and Simulator
  build pass for the offline-resilience revision.
- [ ] Backup and restore are exercised once against disposable Beta data.

## App Store Connect gate

- [x] Current candidate identity is `0.8.0` build `4`; build `3` was the prior TestFlight upload.
- [x] Apple Developer team `6JGQ5388N8` and App ID `com.firepika.BudgetApp` are available locally.
- [x] Build number was incremented for this upload.
- [ ] Confirm export-compliance answers for the app's use of Apple-provided HTTPS/Keychain APIs.
- [ ] Complete App Privacy answers consistently with the self-hosted data model and manifest.
- [ ] Provide support URL/contact, privacy-policy URL, Beta description and tester instructions.
- [ ] Produce required screenshots from the approved Release candidate.
- [x] Public Xcode 27.0 signed, validated, and uploaded `0.8.0 (2)`; App Store Connect accepted the package for processing.
- [ ] Add internal testers and verify install, launch, server connection and feedback path.

The prepared Beta description, test focus and known boundaries are in
[BETA1-TESTER-NOTES.md](BETA1-TESTER-NOTES.md). Contact details and public URLs intentionally remain
owner-provided values rather than invented placeholders.

A factual implementation-based privacy draft is available in
[BETA1-PRIVACY-DISCLOSURE.md](BETA1-PRIVACY-DISCLOSURE.md). It requires owner/legal review, contact
details and public hosting before use; it must not be published as-is with placeholders.

## Minimal human acceptance flow

Use disposable Beta data; do not reset the existing human Live database.

1. Install the Release candidate and connect/authenticate to the disposable server.
2. Complete or skip the guided tour; create the first budget if needed.
3. Create checking with a starting balance, then create a group and category.
4. Assign money, post one categorized expense, and confirm Plan and Activity update.
5. Clear the expense, reconcile it, and confirm the reconciled row is immutable.
6. Create a schedule, enter it once, and confirm forecast becomes posted Activity exactly once.
7. Open Home, Spending Breakdown and Debt; confirm no duplicate alerts or termination.
8. Force-quit and relaunch; confirm the active budget and authoritative values persist.
9. Open Profile & Settings and share diagnostic details; confirm no financial data appears.

## Current verdict

**ENGINEERING PACKAGE:** local-first release candidate verified and archiveable.

**TESTFLIGHT READY:** `0.8.0 (4)` is the current engineering candidate. Upload and App Store Connect
processing remain required; no human acceptance is inferred from a successful upload.

## Signing handoff

Apple approved the developer enrollment on 2026-09-30. The Apple Development and Apple Distribution
identities for team `6JGQ5388N8` are installed.
No `DEVELOPMENT_TEAM` is committed to the project: the release helper applies the owner's team only
to the archive invocation, keeping personal team configuration out of Git. In Xcode Beta:

1. Open **Xcode > Settings > Accounts** and sign in to the enrolled Apple Developer account.
2. Open `ios/BudgetApp.xcodeproj`, select **BudgetApp > Signing & Capabilities**, and choose the
   intended team for Release.
3. Confirm that the registered App ID should be `com.firepika.BudgetApp` before allowing Xcode to
   create/download signing assets.
4. Re-run the signed archive and Xcode validation; never commit a personal provisioning profile.

After Xcode has installed a signing identity, obtain the 10-character Team ID from the account's
membership details and run:

```sh
export BUDGET_APP_DEVELOPMENT_TEAM='ABCDEFGHIJ'
scripts/ios-release.sh preflight
scripts/ios-release.sh archive
```

The helper uses the public `/Applications/Xcode.app` by default because App Store Connect does not
accept archives produced by prerelease Xcode builds. It verifies the Team ID,
installed code-signing identity, `com.firepika.BudgetApp`, marketing/build versions, and Release
settings before creating a timestamped archive. It refuses to overwrite an archive and stores output
under the ignored `artifacts/archives/` directory. It does not upload, change App Store Connect, or
commit provisioning material. Validate and upload the resulting archive deliberately through Xcode
Organizer after the remaining release gates pass.
