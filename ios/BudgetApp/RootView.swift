import BudgetAPI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.composition == .deterministic {
                BudgetWorkspaceView.demo()
            } else if session.serverURL == nil || needsServerConfiguration {
                ServerSetupView()
            } else if session.connectionStatus == .connecting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to Budget Server…").foregroundStyle(.secondary)
                }
            } else if session.connectionStatus == .setupRequired {
                AuthenticationView(firstRun: true)
            } else if session.token == nil {
                AuthenticationView(firstRun: false)
            } else {
                BudgetListView()
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
        // One lifecycle owner. This runs once for the initial active scene and once for each genuine
        // background -> active transition; separate `.task` + `scenePhase` callbacks raced at launch.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await session.validateSelectedSource(caller: "RootView.sceneTask")
        }
    }

    private var needsServerConfiguration: Bool {
        switch session.connectionStatus {
        case .unreachable, .invalidConfiguration: true
        default: false
        }
    }
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

private struct AuthenticationView: View {
    @EnvironmentObject private var session: AppSession
    let firstRun: Bool
    @State private var mode: Int
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var householdName = ""
    @State private var invitationToken = ""

    init(firstRun: Bool = false) {
        self.firstRun = firstRun
        _mode = State(initialValue: firstRun ? 1 : 0)
    }

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
                    Picker("Mode", selection: $mode) {
                        Text("Sign in").tag(0)
                        Text("First-time setup").tag(1)
                        Text("Join family").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if mode != 0 {
                    TextField("Your name", text: $displayName)
                }
                if mode == 1 {
                    TextField("Household name", text: $householdName)
                }
                if mode == 2 {
                    TextField("Invitation code", text: $invitationToken, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                SecureField("Password", text: $password)
                if mode != 0 {
                    // New credentials must satisfy the server's 12-character minimum. Validate before
                    // submission so a short password never returns an opaque server-side 422.
                    Text(!password.isEmpty && password.count < 12 ? "Password must be at least 12 characters." : "Use at least 12 characters.")
                        .font(.caption)
                        .foregroundStyle(!password.isEmpty && password.count < 12 ? Color.red : Color.secondary)
                }
                Button(actionTitle) {
                    Task {
                        if mode == 0 {
                            await session.login(email: email, password: password)
                        } else if mode == 1 {
                            await session.bootstrap(
                                email: email,
                                password: password,
                                displayName: displayName,
                                householdName: householdName
                            )
                        } else {
                            await session.acceptInvitation(
                                token: invitationToken,
                                password: password,
                                displayName: displayName
                            )
                        }
                    }
                }
                .disabled(session.isWorking || !formIsValid)
                Button("Use a different server", role: .cancel) { session.changeServer() }
            }
            .navigationTitle(firstRun ? "First-Time Setup" : "Budget App")
            .overlay { if session.isWorking { ProgressView() } }
        }
    }

    private var actionTitle: String {
        switch mode {
        case 1: "Create owner account"
        case 2: "Join household"
        default: "Sign in"
        }
    }

    // Mirror the backend contract (bootstrap/accept-invitation: password >= 12, email >= 3,
    // display/household names non-blank) so the primary action stays disabled until a request would
    // pass validation, rather than surfacing a server-side 422 as the user's first feedback.
    private var formIsValid: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case 1: return password.count >= 12 && trimmedEmail.count >= 3 && hasName && !householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 2: return password.count >= 12 && hasName && !invitationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return !password.isEmpty && !trimmedEmail.isEmpty
        }
    }
}

private struct BudgetListView: View {
    @EnvironmentObject private var session: AppSession
    @State private var showingBudgetCreation = false
    @State private var selectedBudget: APIBudget?

    var body: some View {
        NavigationStack {
            List(session.budgets) { budget in
                Button { selectedBudget = budget } label: {
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
                        Button { Task { await session.loadBudgets(caller: "BudgetListView.toolbar") } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await session.loadBudgets(caller: "BudgetListView.task") }
            .refreshable { await session.loadBudgets(caller: "BudgetListView.refreshable") }
            .sheet(isPresented: $showingBudgetCreation) {
                BudgetCreationView(households: ownerHouseholds)
            }
            // A workspace owns the navigation stack for each tab. Present it as a root instead of
            // nesting those stacks inside this list's stack, which otherwise hides tab titles and
            // toolbar actions on current SwiftUI releases.
            .fullScreenCover(item: $selectedBudget) { budget in
                BudgetWorkspaceView(budget: budget, canDismiss: true)
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

private struct BudgetCreationView: View {
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
