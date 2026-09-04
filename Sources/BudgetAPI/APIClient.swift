import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIClientError: LocalizedError, Equatable {
    case invalidServerURL
    case insecureRemoteServer
    case invalidResponse
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid server address."
        case .insecureRemoteServer: "Remote servers must use HTTPS."
        case .invalidResponse: "The server returned an unreadable response."
        case let .server(_, message): message
        }
    }
}

public struct APIClient {
    let baseURL: URL
    var session: URLSession = .shared

    public init(baseURL: URL, session: URLSession = .shared) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              baseURL.host != nil else {
            throw APIClientError.invalidServerURL
        }
        if scheme == "http", !Self.isLocalHost(baseURL.host) {
            throw APIClientError.insecureRemoteServer
        }
        self.baseURL = baseURL
        self.session = session
    }

    public func health() async throws {
        let _: [String: String] = try await send(path: "api/v1/health")
    }

    public func login(email: String, password: String) async throws -> String {
        let response: TokenResponse = try await send(
            path: "api/v1/auth/login",
            method: "POST",
            body: LoginRequest(email: email, password: password)
        )
        return response.accessToken
    }

    public func bootstrap(_ request: BootstrapRequest) async throws -> String {
        let response: TokenResponse = try await send(
            path: "api/v1/auth/bootstrap",
            method: "POST",
            body: request
        )
        return response.accessToken
    }

    public func acceptInvitation(_ request: APIInvitationAccept) async throws -> String {
        let response: TokenResponse = try await send(
            path: "api/v1/auth/accept-invitation",
            method: "POST",
            body: request
        )
        return response.accessToken
    }

    public func profile(token: String) async throws -> APIProfile {
        try await send(path: "api/v1/me", token: token)
    }

    public func budgets(token: String) async throws -> [APIBudget] {
        try await send(path: "api/v1/budgets", token: token)
    }

    public func createBudget(_ budget: APIBudgetCreate, token: String) async throws -> APIBudget {
        try await send(path: "api/v1/budgets", method: "POST", token: token, body: budget)
    }

    public func accounts(budgetID: String, token: String) async throws -> [APIAccount] {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts", token: token)
    }

    public func createAccount(
        budgetID: String,
        account: APIAccountCreate,
        token: String
    ) async throws -> APIAccount {
        try await send(
            path: "api/v1/budgets/\(budgetID)/accounts",
            method: "POST",
            token: token,
            body: account
        )
    }

    public func categoryGroups(budgetID: String, token: String) async throws -> [APICategoryGroup] {
        try await send(path: "api/v1/budgets/\(budgetID)/category-groups", token: token)
    }

    public func createCategoryGroup(
        budgetID: String,
        group: APICategoryGroupCreate,
        token: String
    ) async throws -> APICategoryGroup {
        try await send(
            path: "api/v1/budgets/\(budgetID)/category-groups",
            method: "POST",
            token: token,
            body: group
        )
    }

    public func transactions(budgetID: String, token: String) async throws -> [APITransaction] {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions", token: token)
    }

    public func categories(budgetID: String, token: String) async throws -> [APICategory] {
        try await send(path: "api/v1/budgets/\(budgetID)/categories", token: token)
    }

    public func createCategory(
        budgetID: String,
        category: APICategoryCreate,
        token: String
    ) async throws -> APICategory {
        try await send(
            path: "api/v1/budgets/\(budgetID)/categories",
            method: "POST",
            token: token,
            body: category
        )
    }

    public func createTransaction(
        budgetID: String,
        transaction: APITransactionCreate,
        token: String
    ) async throws -> APITransaction {
        try await send(
            path: "api/v1/budgets/\(budgetID)/transactions",
            method: "POST",
            token: token,
            body: transaction
        )
    }

    public func updateAssignment(
        budgetID: String,
        categoryID: String,
        month: String,
        assignedMinor: Int64,
        token: String
    ) async throws -> APIAssignment {
        try await send(
            path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/assignment",
            method: "PUT",
            token: token,
            body: APIAssignmentUpdate(month: month, assignedMinor: assignedMinor)
        )
    }

    public func monthSummary(
        budgetID: String,
        month: String,
        token: String
    ) async throws -> APIMonthSummary {
        try await send(path: "api/v1/budgets/\(budgetID)/months/\(month)", token: token)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        token: String? = nil
    ) async throws -> Response {
        try await send(path: path, method: method, token: token, bodyData: nil)
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        token: String? = nil,
        body: Body
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        return try await send(path: path, method: method, token: token, bodyData: data)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        token: String?,
        bodyData: Data?
    ) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data).detail)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIClientError.server(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIClientError.invalidResponse
        }
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
