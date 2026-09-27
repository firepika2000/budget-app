# Budget App Beta privacy disclosure — draft for owner review

Last updated: 2026-09-27

This draft describes the current closed-Beta implementation. It must be reviewed, supplied with an
owner/operator identity and contact method, and hosted at a public URL before external TestFlight or
App Store use. It is product documentation, not legal advice.

## How Budget App handles data

Budget App lets you connect to a Budget Server chosen by you or your test organizer. In Live mode,
the app sends the information needed to provide budgeting features to that selected server. This can
include account and household identity information, budget structure, account balances,
transactions, payees, categories, schedules, reports, access settings and attachments you choose.

The iPhone app does not include advertising or third-party analytics SDKs and does not track you
across apps or websites. The app developer does not automatically receive the contents of a
self-hosted Budget Server. The operator of the server you select controls that server's storage,
access, backups and network environment.

## Information stored on the device

- Authentication tokens are stored in the iOS Keychain.
- App preferences such as the selected data source, active budget, appearance, Hide Amounts and
  guided-tour progress are stored in app-local preferences.
- Deterministic Demo financial data exists only as temporary in-process sample data and resets when
  the app process is relaunched.

## Camera, photos and files

Budget App accesses the camera only after you choose **Take Photo** for a transaction attachment.
Photo and file pickers provide only the items you select. Selected PDF, JPEG, PNG or HEIC files are
uploaded through the same authorized attachment service to your chosen Budget Server. A detached
attachment is unavailable from the transaction and is retained for 30 days before permanent server
deletion under the current Beta policy.

## Household sharing

Budget owners can invite household members and configure access. The server enforces the member's
authorized accounts, categories and capabilities. Household members should contact the household
owner or server operator about access correction or removal.

## Security and retention

Budget App uses the selected server's configured network connection. HTTPS should be used except
for explicit local development. Refresh credentials rotate, and the server stores refresh secrets as
hashes. Attachment content is stored encrypted by the Budget Server implementation. Backup and
retention practices remain the responsibility of the selected server operator.

## Apple TestFlight

When you install a Beta through TestFlight, Apple may process installation, diagnostic and crash
information under Apple's own terms and privacy policy. That processing is separate from Budget
App's self-hosted server architecture.

## Your choices

You can decline camera access and use Photos or Files instead. You can disconnect from a server or
sign out. Requests to access, correct, export or delete Live household data must be directed to the
operator of the selected Budget Server during this closed Beta.

## Contact

Owner/operator name: **TO BE PROVIDED**

Privacy/support contact: **TO BE PROVIDED**

Public privacy-policy URL: **TO BE PROVIDED**
