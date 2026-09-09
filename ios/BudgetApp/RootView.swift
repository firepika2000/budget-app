import BudgetAPI
import SwiftUI

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

    var body: some View {
        NavigationStack {
            Form {
                Section("Data Source") {
                    LabeledContent("Mode", value: "Live Budget Server")
                    Button("Use Deterministic Demo") { session.selectDeterministic() }
                    Text("Demo data is temporary and is not your authoritative household database.")
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
            }
            .navigationTitle("Connect Budget App")
            .overlay { if session.isWorking { ProgressView() } }
            .onAppear { if let url = session.serverURL { address = url.absoluteString } }
        }
    }

    private var connectionSymbol: String {
        switch session.connectionStatus {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .authenticationRequired: "person.badge.key"
        case .setupRequired: "sparkles"
        case .deterministic: "shippingbox"
        case .unreachable, .invalidConfiguration: "exclamationmark.triangle.fill"
        }
    }
}

struct ServerConnectionSettingsView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: AppDataSourceMode = .deterministic
    @State private var address = "http://127.0.0.1:8000"

    var body: some View {
        Form {
            Section("Data Source") {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(AppDataSourceMode.allCases) { Text($0.title).tag($0) }
                }
                Text(selectedMode == .deterministic
                     ? "Uses temporary acceptance fixtures. Changes do not belong to your live household and reset on relaunch."
                     : "Uses the authoritative Budget Server. Changes are sent to that server and persist there.")
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
                Button(selectedMode == .deterministic ? "Use Deterministic Demo" : "Test and Connect") {
                    if selectedMode == .deterministic { session.selectDeterministic(); dismiss() }
                    else { Task { await session.configureServer(address) } }
                }
                .disabled(session.isWorking || (selectedMode == .liveServer && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .navigationTitle("Server Connection")
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
                }
                if form.mode == 1 {
                    TextField("Household name", text: $form.householdName)
                }
                if form.mode == 2 {
                    TextField("Invitation code", text: $form.invitationToken, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("Email", text: $form.email)
                        .accessibilityIdentifier("auth-email-field")
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                SecureField("Password", text: $form.password)
                    .accessibilityIdentifier("auth-password-field")
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
            }
            .navigationTitle(firstRun ? "First-Time Setup" : "Budget App")
            .overlay { if session.isWorking { ProgressView() } }
            .onAppear { if firstRun && form.mode == 0 { form.mode = 1 } }
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
                                householdID: householdID
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
