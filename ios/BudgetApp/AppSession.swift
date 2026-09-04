import Foundation
import BudgetAPI

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var serverURL: URL?
    @Published private(set) var token: String?
    @Published var budgets: [APIBudget] = []
    @Published var isWorking = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let serverKey = "budget.serverURL"
    private let tokenAccount = "access-token"

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if let stored = defaults.string(forKey: serverKey) {
            self.serverURL = URL(string: stored)
        }
        self.token = keychain.read(account: tokenAccount)
    }

    func configureServer(_ rawValue: String) async {
        await perform {
            guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw APIClientError.invalidServerURL
            }
            let client = try APIClient(baseURL: url)
            try await client.health()
            self.serverURL = url
            self.defaults.set(url.absoluteString, forKey: self.serverKey)
        }
    }

    func login(email: String, password: String) async {
        await authenticate { client in
            try await client.login(email: email, password: password)
        }
    }

    func bootstrap(email: String, password: String, displayName: String, householdName: String) async {
        await authenticate { client in
            try await client.bootstrap(BootstrapRequest(
                email: email,
                password: password,
                displayName: displayName,
                householdName: householdName
            ))
        }
    }

    func loadBudgets() async {
        guard let serverURL, let token else { return }
        await perform {
            self.budgets = try await APIClient(baseURL: serverURL).budgets(token: token)
        }
    }

    func signOut() {
        keychain.delete(account: tokenAccount)
        token = nil
        budgets = []
    }

    func changeServer() {
        signOut()
        defaults.removeObject(forKey: serverKey)
        serverURL = nil
    }

    private func authenticate(_ operation: (APIClient) async throws -> String) async {
        guard let serverURL else { return }
        await perform {
            let newToken = try await operation(APIClient(baseURL: serverURL))
            try self.keychain.save(newToken, account: self.tokenAccount)
            self.token = newToken
            self.budgets = try await APIClient(baseURL: serverURL).budgets(token: newToken)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
