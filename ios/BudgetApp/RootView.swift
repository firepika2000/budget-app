import BudgetAPI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.serverURL == nil {
                ServerSetupView()
            } else if session.token == nil {
                AuthenticationView()
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, session.token != nil {
                Task { await session.loadBudgets() }
            }
        }
    }
}

private struct ServerSetupView: View {
    @EnvironmentObject private var session: AppSession
    @State private var address = "https://"

    var body: some View {
        NavigationStack {
            Form {
                Section("Your server") {
                    TextField("https://budget.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Text("Use HTTPS unless connecting to localhost during development.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Connect") {
                    Task { await session.configureServer(address) }
                }
                .disabled(session.isWorking || address.isEmpty)
            }
            .navigationTitle("Connect Budget App")
            .overlay { if session.isWorking { ProgressView() } }
        }
    }
}

private struct AuthenticationView: View {
    @EnvironmentObject private var session: AppSession
    @State private var mode = 0
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var householdName = ""
    @State private var invitationToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    Text("Sign in").tag(0)
                    Text("First-time setup").tag(1)
                    Text("Join family").tag(2)
                }
                .pickerStyle(.segmented)
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
            .navigationTitle("Budget App")
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

    private var formIsValid: Bool {
        guard !password.isEmpty else { return false }
        if mode == 2 { return !displayName.isEmpty && !invitationToken.isEmpty }
        if mode == 1 { return !email.isEmpty && !displayName.isEmpty && !householdName.isEmpty }
        return !email.isEmpty
    }
}

private struct BudgetListView: View {
    @EnvironmentObject private var session: AppSession
    @State private var showingBudgetCreation = false

    var body: some View {
        NavigationStack {
            List(session.budgets) { budget in
                NavigationLink {
                    BudgetDetailView(budget: budget)
                } label: {
                    VStack(alignment: .leading) {
                        Text(budget.name).font(.headline)
                        Text(budget.currencyCode).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if session.budgets.isEmpty && !session.isWorking {
                    ContentUnavailableView(
                        "No shared budgets",
                        systemImage: "tray",
                        description: Text("Ask the household owner to share a budget with this account.")
                    )
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if !ownerHouseholds.isEmpty {
                            Button { showingBudgetCreation = true } label: {
                                Image(systemName: "plus")
                            }
                        }
                        Button { Task { await session.loadBudgets() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await session.loadBudgets() }
            .refreshable { await session.loadBudgets() }
            .sheet(isPresented: $showingBudgetCreation) {
                BudgetCreationView(households: ownerHouseholds)
            }
        }
    }

    private var ownerHouseholds: [APIHousehold] {
        session.profile?.households.filter { $0.role == "owner" && $0.isActive } ?? []
    }
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
