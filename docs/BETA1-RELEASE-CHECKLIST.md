# Beta 1 TestFlight release checklist

Updated 2026-09-27. This is the short launch gate for the first closed TestFlight build.
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
- [ ] Human Live retest confirms Debt navigation no longer repeats alerts or terminates.
- [ ] One disposable Live user completes the concise core journey and relaunch persistence check.
- [ ] Release-candidate Swift/backend/native smoke suites pass at the selected release commit.
- [ ] Backup and restore are exercised once against disposable Beta data.

## App Store Connect gate

- [x] Beta release identity is intentionally set to `0.8.0` build `1` for the first upload.
- [ ] Select the Apple Developer team and confirm `com.firepika.BudgetApp` is the intended App ID.
- [ ] Increment the build number for every upload.
- [ ] Confirm export-compliance answers for the app's use of Apple-provided HTTPS/Keychain APIs.
- [ ] Complete App Privacy answers consistently with the self-hosted data model and manifest.
- [ ] Provide support URL/contact, privacy-policy URL, Beta description and tester instructions.
- [ ] Produce required screenshots from the approved Release candidate.
- [ ] Create a signed archive, run Xcode validation, then upload to closed TestFlight.
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

**ENGINEERING PACKAGE:** archiveable, not yet release-candidate accepted.

**TESTFLIGHT READY:** NO — human Debt/core-flow acceptance, signing and App Store Connect metadata
remain open.

## Signing handoff

The 2026-09-27 local inspection found `0 valid identities` and no `DEVELOPMENT_TEAM` in the
Release settings. In Xcode Beta:

1. Open **Xcode > Settings > Accounts** and sign in to the enrolled Apple Developer account.
2. Open `ios/BudgetApp.xcodeproj`, select **BudgetApp > Signing & Capabilities**, and choose the
   intended team for Release.
3. Confirm that the registered App ID should be `com.firepika.BudgetApp` before allowing Xcode to
   create/download signing assets.
4. Re-run the signed archive and Xcode validation; never commit a personal provisioning profile.
