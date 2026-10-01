import BudgetAPI
import SwiftUI
import VisionKit
import UIKit
import AVFoundation

struct DevicePairingPayload: Codable, Equatable {
    let version: Int
    let serverURL: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case serverURL = "server_url"
        case code
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ value: String) -> DevicePairingPayload? {
        guard let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.version == 1,
              let url = URL(string: payload.serverURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              !payload.code.isEmpty else { return nil }
        return payload
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    private let authenticationFormOverride: AuthenticationFormState?

    init(authenticationForm: AuthenticationFormState? = nil) {
        authenticationFormOverride = authenticationForm
    }

    var body: some View {
        Group {
            switch session.route {
            case .serverSetup:
                ServerSetupView()
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to Budget Server…").foregroundStyle(.secondary)
                }
            case .serverBootstrap:
                AuthenticationFlowView(firstRun: true, form: authenticationFormOverride)
            case .authentication:
                AuthenticationFlowView(firstRun: false, form: authenticationFormOverride)
            case .budgetSelection:
                BudgetSelectionView()
            case let .workspace(context):
                ActiveBudgetShell(context: context)
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Text(RuntimeBuildIdentity.visibleText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 4)
                .padding(.top, 2)
                .accessibilityLabel("Debug runtime identity \(RuntimeBuildIdentity.visibleText)")
                .accessibilityIdentifier("runtime-build-identity")
                .allowsHitTesting(false)
        }
        .onAppear { session.logRouteTransition(from: nil, to: session.route) }
        .onChange(of: session.route) { oldRoute, newRoute in
            session.logRouteTransition(from: oldRoute, to: newRoute)
        }
        #endif
        .alert("Something went wrong", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
        .task { guard scenePhase == .active else { return }; await session.activate(caller: "RootView.task") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.activate(caller: "RootView.sceneActive") } }
            else { session.deactivate() }
        }
    }
}

struct ActiveBudgetShell: View {
    let context: WorkspaceRouteContext
    var body: some View {
        WorkspaceCompositionRoot(context: context)
            .id(context.identity)
        .accessibilityIdentifier("active-budget-shell")
    }
}

/// The only source-selection boundary below the application shell. Both repositories feed the same
/// BudgetWorkspaceStore and BudgetWorkspaceView; feature views never choose an application mode.
private struct WorkspaceCompositionRoot: View {
    @StateObject private var store: BudgetWorkspaceStore

    init(context: WorkspaceRouteContext) {
        _store = StateObject(wrappedValue: .production(context: context))
    }

    var body: some View { BudgetWorkspaceView(store: store) }
}

private struct ServerSetupView: View {
    @EnvironmentObject private var session: AppSession
    @State private var address = "https://"
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            Form {
            Section("Data Source") {
                    LabeledContent("Mode", value: "On This iPhone")
                    Button("Start on This iPhone") { session.selectLocalDevice() }
                    Text("Your budget remains available without a server or internet connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Your server") {
                    TextField("https://budget.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Text("Use HTTPS unless connecting to localhost during development.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Connection Status") {
                    Label(session.connectionStatus.title, systemImage: connectionSymbol)
                    if let detail = session.connectionStatus.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Button("Connect") {
                    Task { await session.configureServer(address) }
                }
                .disabled(session.isWorking || address.isEmpty)
                Section("Pair This iPhone") {
                    Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") {
                        showingPairing = true
                    }
                    Text("On an already connected device, open Profile & Settings → Devices to create a five-minute pairing code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect Budget App")
            .overlay { if session.isWorking { ProgressView() } }
            .onAppear { if let url = session.serverURL { address = url.absoluteString } }
            .sheet(isPresented: $showingPairing) { PairingJoinView() }
        }
    }

    private var connectionSymbol: String {
        switch session.connectionStatus {
        case .localDevice: "iphone"
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .authenticationRequired: "person.badge.key"
        case .setupRequired: "sparkles"
        case .deterministic: "shippingbox"
        case .unreachable, .invalidConfiguration: "exclamationmark.triangle.fill"
        }
    }
}

struct PairingJoinView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var serverAddress = "https://"
    @State private var code = ""
    @State private var showingScanner = false
    @State private var validationMessage: String?

    init(serverAddress: String? = nil) {
        _serverAddress = State(initialValue: serverAddress ?? "https://")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                        openScanner()
                    }
                    .accessibilityIdentifier("scan-device-pairing-code")
                } footer: {
                    Text("The QR contains only the secure server address and a one-time five-minute code. It never contains your password or budget data.")
                }
                Section("Manual Entry") {
                    TextField("https://budget.example.com", text: $serverAddress)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    TextField("Pairing code", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                    if let validationMessage { Text(validationMessage).font(.footnote).foregroundStyle(.red) }
                    Button("Pair This iPhone") { pair() }
                        .disabled(session.isWorking || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("pair-this-device")
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if session.isWorking { ProgressView() } }
            .sheet(isPresented: $showingScanner) {
                PairingCodeScanner { value in
                    showingScanner = false
                    guard let payload = DevicePairingPayload.parse(value) else {
                        validationMessage = "That QR code is not a valid ClearPocket device pairing code."
                        return
                    }
                    serverAddress = payload.serverURL
                    code = payload.code
                    pair()
                }
                .ignoresSafeArea()
            }
        }
    }

    private func pair() {
        validationMessage = nil
        Task {
            await session.pairDevice(serverAddress: serverAddress, code: code)
            // A successful redemption changes the authoritative application route to the Live
            // workspace. Let that route replacement tear down this sheet once; explicitly
            // dismissing at the same time can race SwiftUI's presentation coordinator.
        }
    }

    private func openScanner() {
        guard DataScannerViewController.isSupported else {
            validationMessage = "QR scanning is unavailable on this device. Enter the server and pairing code instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard DataScannerViewController.isAvailable else {
                validationMessage = "The camera is currently unavailable. Enter the pairing details manually or try again later."
                return
            }
            showingScanner = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    if DataScannerViewController.isAvailable { showingScanner = true }
                    else { validationMessage = "The camera is currently unavailable. Enter the pairing details manually or try again later." }
                } else {
                    validationMessage = "Camera access was denied. You can enter the pairing details manually or enable Camera access in Settings."
                }
            }
        case .denied, .restricted:
            validationMessage = "Camera access is unavailable. Enter the pairing details manually or enable Camera access in Settings."
        @unknown default:
            validationMessage = "QR scanning is unavailable. Enter the pairing details manually."
        }
    }
}

private struct PairingCodeScanner: UIViewControllerRepresentable {
    let completion: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        DispatchQueue.main.async { try? scanner.startScanning() }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let completion: (String) -> Void
        private var completed = false
        init(completion: @escaping (String) -> Void) { self.completion = completion }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                completed = true
                dataScanner.stopScanning()
                completion(value)
                return
            }
        }
    }
}

struct ServerConnectionSettingsView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: AppDataSourceMode = .localDevice
    @State private var address = "http://127.0.0.1:8000"

    var body: some View {
        Form {
            Section("Data Source") {
                Picker("Mode", selection: $selectedMode) {
                    Text(AppDataSourceMode.localDevice.title).tag(AppDataSourceMode.localDevice)
                    Text(AppDataSourceMode.liveServer.title).tag(AppDataSourceMode.liveServer)
                }
                Text(selectedMode == .localDevice
                     ? "Your iPhone is the authority. Your budget works without an internet connection and stays private on this device."
                     : "Move to a server you control for multi-device or household access. Migration and pairing will preserve your local data.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if selectedMode == .liveServer {
                Section("Server Address") {
                    TextField("http://127.0.0.1:8000", text: $address)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    Text("Raw addresses are available for development acceptance. Discovery and secure pairing remain future work.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Connection Status") {
                LabeledContent("Status", value: session.connectionStatus.title)
                if let detail = session.connectionStatus.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                if let url = session.serverURL { LabeledContent("Server", value: url.absoluteString) }
            }
            Section {
                Button(selectedMode == .localDevice ? "Keep Data on This iPhone" : "Connect to Existing Server") {
                    if selectedMode == .localDevice { session.selectLocalDevice(); dismiss() }
                    else { Task { await session.configureServer(address) } }
                }
                .disabled(session.isWorking || (selectedMode == .liveServer && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            Section("Training") {
                Button("Open Example Budget") {
                    session.selectDeterministic()
                    dismiss()
                }
                Text("The example is temporary and separate from your real budget. Use it only to learn or explore features.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data Location")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if session.isWorking { ProgressView() } }
        .onAppear {
            selectedMode = session.sourceMode
            if let url = session.serverURL { address = url.absoluteString }
        }
    }
}

final class AuthenticationFormState: ObservableObject {
    @Published var mode = 0
    @Published var email = ""
    @Published var password = ""
    @Published var displayName = ""
    @Published var householdName = ""
    @Published var invitationToken = ""
}

private struct AuthenticationFlowView: View {
    let firstRun: Bool
    @StateObject private var form: AuthenticationFormState
    init(firstRun: Bool, form: AuthenticationFormState? = nil) {
        self.firstRun = firstRun
        _form = StateObject(wrappedValue: form ?? AuthenticationFormState())
    }
    var body: some View { AuthenticationView(firstRun: firstRun, form: form) }
}

struct AuthenticationView: View {
    @EnvironmentObject private var session: AppSession
    let firstRun: Bool
    @ObservedObject var form: AuthenticationFormState
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Connection") {
                    LabeledContent("Status", value: session.connectionStatus.title)
                    LabeledContent("Server", value: session.serverURL?.absoluteString ?? "Not configured")
                }
                if firstRun {
                    Section {
                        Text("This Budget Server has not been set up yet. Create the first household and its owner account to begin.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Mode", selection: $form.mode) {
                        Text("Sign in").tag(0)
                        Text("First-time setup").tag(1)
                        Text("Join family").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if form.mode != 0 {
                    TextField("Your name", text: $form.displayName)
                        .textContentType(.name)
                }
                if form.mode == 1 {
                    TextField("Household name", text: $form.householdName)
                        .textContentType(.organizationName)
                }
                if form.mode == 2 {
                    TextField("Invitation code", text: $form.invitationToken, axis: .vertical)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("Email", text: $form.email)
                        .accessibilityIdentifier("auth-email-field")
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                SecureField("Password", text: $form.password)
                    .accessibilityIdentifier("auth-password-field")
                    .textContentType(form.mode == 0 ? .password : .newPassword)
                if form.mode != 0 {
                    // New credentials must satisfy the server's 12-character minimum. Validate before
                    // submission so a short password never returns an opaque server-side 422.
                    Text(!form.password.isEmpty && form.password.count < 12 ? "Password must be at least 12 characters." : "Use at least 12 characters.")
                        .font(.caption)
                        .foregroundStyle(!form.password.isEmpty && form.password.count < 12 ? Color.red : Color.secondary)
                }
                Button(actionTitle) {
                    Task {
                        if form.mode == 0 {
                            await session.login(email: form.email, password: form.password)
                        } else if form.mode == 1 {
                            await session.bootstrap(
                                email: form.email,
                                password: form.password,
                                displayName: form.displayName,
                                householdName: form.householdName
                            )
                        } else {
                            await session.acceptInvitation(
                                token: form.invitationToken,
                                password: form.password,
                                displayName: form.displayName
                            )
                        }
                    }
                }
                .disabled(session.isWorking || !formIsValid)
                Button("Use a different server", role: .cancel) { session.changeServer() }
                if !firstRun {
                    Section("Pairing") {
                        Button("Pair with Another Device", systemImage: "qrcode.viewfinder") {
                            showingPairing = true
                        }
                        Text("Use a one-time code created by an already signed-in device. No password is shared.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(firstRun ? "First-Time Setup" : "Budget App")
            .overlay { if session.isWorking { ProgressView() } }
            .onAppear { if firstRun && form.mode == 0 { form.mode = 1 } }
            .sheet(isPresented: $showingPairing) {
                PairingJoinView(serverAddress: session.serverURL?.absoluteString)
            }
        }
    }

    private var actionTitle: String {
        switch form.mode {
        case 1: "Create owner account"
        case 2: "Join household"
        default: "Sign in"
        }
    }

    // Mirror the backend contract (bootstrap/accept-invitation: password >= 12, email >= 3,
    // display/household names non-blank) so the primary action stays disabled until a request would
    // pass validation, rather than surfacing a server-side 422 as the user's first feedback.
    private var formIsValid: Bool {
        let trimmedEmail = form.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = !form.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch form.mode {
        case 1: return form.password.count >= 12 && trimmedEmail.count >= 3 && hasName && !form.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 2: return form.password.count >= 12 && hasName && !form.invitationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return !form.password.isEmpty && !trimmedEmail.isEmpty
        }
    }
}

struct BudgetSelectionView: View {
    @EnvironmentObject private var session: AppSession
    @State private var showingBudgetCreation = false

    var body: some View {
        NavigationStack {
            List(session.budgets) { budget in
                Button { session.selectBudget(budget.id) } label: {
                    VStack(alignment: .leading) {
                        Text(budget.name).font(.headline)
                        Text(budget.currencyCode).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if session.budgets.isEmpty && !session.isWorking {
                    if canCreateBudget {
                        // The signed-in user owns an active household, so the zero-Budget state is an
                        // invitation to create the first one — not a request to wait for a share.
                        ContentUnavailableView {
                            Label("No budgets yet", systemImage: "tray")
                        } description: {
                            Text("Create your first budget to start organizing your household's money.")
                        } actions: {
                            Button("Create Budget") { showingBudgetCreation = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView(
                            "No shared budgets",
                            systemImage: "tray",
                            description: Text("Ask the household owner to share a budget with this account.")
                        )
                    }
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if canCreateBudget {
                            Button { showingBudgetCreation = true } label: {
                                Image(systemName: "plus")
                            }
                        }
                        Button { Task { await session.loadBudgets(caller: "BudgetSelectionView.toolbar") } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await session.loadBudgets(caller: "BudgetSelectionView.refreshable") }
            .sheet(isPresented: $showingBudgetCreation) {
                BudgetCreationView(households: ownerHouseholds)
            }
        }
    }

    private var ownerHouseholds: [APIHousehold] {
        session.profile?.households.filter { $0.role == "owner" && $0.isActive } ?? []
    }

    // The same signal that gates the "+" toolbar action: whether the user owns an active household
    // and may therefore create a Budget. Drives capability-appropriate empty-state copy.
    private var canCreateBudget: Bool { !ownerHouseholds.isEmpty }
}

struct BudgetCreationView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    let households: [APIHousehold]
    @State private var name = ""
    @State private var currencyCode = Locale.current.currency?.identifier ?? "USD"
    @State private var householdID = ""
    @State private var cashRolloverPolicy: APICashRolloverPolicy = .absorbNextMonth

    var body: some View {
        NavigationStack {
            Form {
                TextField("Budget name", text: $name)
                Picker("Household", selection: $householdID) {
                    ForEach(households) { Text($0.name).tag($0.id) }
                }
                TextField("Currency code", text: $currencyCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Section("Cash overspending") {
                    Picker("Rollover policy", selection: $cashRolloverPolicy) {
                        Text("Absorb next month (recommended)").tag(APICashRolloverPolicy.absorbNextMonth)
                        Text("Carry category deficit").tag(APICashRolloverPolicy.carryCategoryDeficit)
                    }.pickerStyle(.inline)
                    Text("Absorb clears an unresolved cash category deficit next month and reduces Unassigned once. Carry keeps the deficit in its category. Credit-card debt stays separate. Later changes are prospective.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await session.createBudget(
                                name: name,
                                currencyCode: currencyCode.uppercased(),
                                householdID: householdID,
                                cashRolloverPolicy: cashRolloverPolicy
                            )
                            if session.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(session.isWorking || name.isEmpty || householdID.isEmpty || currencyCode.count != 3)
                }
            }
            .onAppear { if householdID.isEmpty { householdID = households.first?.id ?? "" } }
        }
    }
}
