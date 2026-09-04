import Foundation
import BudgetAPI

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var serverURL: URL?
    @Published private(set) var token: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var profile: APIProfile?
    @Published var budgets: [APIBudget] = []
    @Published var isWorking = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let serverKey = "budget.serverURL"
    private let tokenAccount = "access-token"
    private let refreshTokenAccount = "refresh-token"

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if let stored = defaults.string(forKey: serverKey) {
            self.serverURL = URL(string: stored)
        }
        self.token = keychain.read(account: tokenAccount)
        self.refreshToken = keychain.read(account: refreshTokenAccount)
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

    func acceptInvitation(token invitationToken: String, password: String, displayName: String) async {
        await authenticate { client in
            try await client.acceptInvitation(APIInvitationAccept(
                invitationToken: invitationToken,
                password: password,
                displayName: displayName
            ))
        }
    }

    func loadBudgets() async {
        await perform {
            try await self.refreshIfNeeded()
            guard let serverURL = self.serverURL, let token = self.token else { return }
            let client = try APIClient(baseURL: serverURL)
            async let profile = client.profile(token: token)
            async let budgets = client.budgets(token: token)
            (self.profile, self.budgets) = try await (profile, budgets)
        }
    }

    func createBudget(name: String, currencyCode: String, householdID: String) async {
        guard let serverURL, let token else { return }
        await perform {
            let client = try APIClient(baseURL: serverURL)
            _ = try await client.createBudget(
                APIBudgetCreate(householdID: householdID, name: name, currencyCode: currencyCode),
                token: token
            )
            self.budgets = try await client.budgets(token: token)
        }
    }

    func signOut() {
        if let serverURL, let refreshToken {
            Task { try? await APIClient(baseURL: serverURL).logout(refreshToken) }
        }
        keychain.delete(account: tokenAccount)
        keychain.delete(account: refreshTokenAccount)
        token = nil
        refreshToken = nil
        budgets = []
        profile = nil
    }

    func changeServer() {
        signOut()
        defaults.removeObject(forKey: serverKey)
        serverURL = nil
    }

    private func authenticate(_ operation: (APIClient) async throws -> APIAuthTokens) async {
        guard let serverURL else { return }
        await perform {
            let tokens = try await operation(APIClient(baseURL: serverURL))
            try self.save(tokens)
            let client = try APIClient(baseURL: serverURL)
            async let profile = client.profile(token: tokens.accessToken)
            async let budgets = client.budgets(token: tokens.accessToken)
            (self.profile, self.budgets) = try await (profile, budgets)
        }
    }

    func refreshIfNeeded(force: Bool = false) async throws {
        guard let serverURL, let refreshToken else { return }
        if !force, let token, Self.secondsUntilExpiration(token) > 90 { return }
        let tokens = try await APIClient(baseURL: serverURL).refresh(refreshToken)
        try save(tokens)
    }

    private func save(_ tokens: APIAuthTokens) throws {
        try keychain.save(tokens.accessToken, account: tokenAccount)
        do {
            try keychain.save(tokens.refreshToken, account: refreshTokenAccount)
        } catch {
            keychain.delete(account: tokenAccount)
            throw error
        }
        token = tokens.accessToken
        refreshToken = tokens.refreshToken
    }

    private static func secondsUntilExpiration(_ token: String) -> TimeInterval {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return 0 }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = object["exp"] as? TimeInterval else { return 0 }
        return expiration - Date().timeIntervalSince1970
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
