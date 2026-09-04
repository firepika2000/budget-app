# iPhone app

`BudgetApp` is a native SwiftUI iPhone client. It supports server selection, first-owner bootstrap, sign-in, Keychain token storage, and privacy-filtered budget listing.

## Generate the Xcode project

The generated `BudgetApp.xcodeproj` is committed for convenience. When `project.yml` or the source layout changes, regenerate it with XcodeGen 2.46 or newer:

```sh
xcodegen generate
```

Open `BudgetApp.xcodeproj`, select an iPhone simulator or connected device, choose a development team if needed, and run the `BudgetApp` scheme.

For security, the client accepts HTTP only for `localhost`. Home-server and internet-accessible installations must provide HTTPS.

