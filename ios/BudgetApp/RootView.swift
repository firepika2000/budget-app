import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession

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

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    Text("Sign in").tag(0)
                    Text("First-time setup").tag(1)
                }
                .pickerStyle(.segmented)
                if mode == 1 {
                    TextField("Your name", text: $displayName)
                    TextField("Household name", text: $householdName)
                }
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button(mode == 0 ? "Sign in" : "Create owner account") {
                    Task {
                        if mode == 0 {
                            await session.login(email: email, password: password)
                        } else {
                            await session.bootstrap(
                                email: email,
                                password: password,
                                displayName: displayName,
                                householdName: householdName
                            )
                        }
                    }
                }
                .disabled(session.isWorking || email.isEmpty || password.isEmpty)
                Button("Use a different server", role: .cancel) { session.changeServer() }
            }
            .navigationTitle("Budget App")
            .overlay { if session.isWorking { ProgressView() } }
        }
    }
}

private struct BudgetListView: View {
    @EnvironmentObject private var session: AppSession

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
                    Button { Task { await session.loadBudgets() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await session.loadBudgets() }
            .refreshable { await session.loadBudgets() }
        }
    }
}
