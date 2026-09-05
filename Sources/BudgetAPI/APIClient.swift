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

    public func login(email: String, password: String) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/login",
            method: "POST",
            body: LoginRequest(email: email, password: password)
        )
    }

    public func bootstrap(_ request: BootstrapRequest) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/bootstrap",
            method: "POST",
            body: request
        )
    }

    public func acceptInvitation(_ request: APIInvitationAccept) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/accept-invitation",
            method: "POST",
            body: request
        )
    }

    public func refresh(_ refreshToken: String) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/refresh",
            method: "POST",
            body: APIRefreshRequest(refreshToken: refreshToken)
        )
    }

    public func logout(_ refreshToken: String) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/auth/logout",
            method: "POST",
            body: APIRefreshRequest(refreshToken: refreshToken)
        )
    }

    public func profile(token: String) async throws -> APIProfile {
        try await send(path: "api/v1/me", token: token)
    }

    public func householdMembers(householdID: String, token: String) async throws -> [APIHouseholdMember] {
        try await send(path: "api/v1/households/\(householdID)/members", token: token)
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

    public func accountBalance(budgetID: String, accountID: String, token: String) async throws -> APIAccountBalance {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/balance", token: token)
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

    public func allocationOperations(budgetID: String, token: String) async throws -> [APIAllocationOperation] {
        try await send(path: "api/v1/budgets/\(budgetID)/allocations", token: token)
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

    public func updateCategory(budgetID: String, categoryID: String, category: APICategoryUpdate, token: String) async throws -> APICategory {
        try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)", method: "PUT", token: token, body: category)
    }

    public func updateCategoryDelegation(budgetID: String, categoryID: String, delegatedUserID: String?, token: String) async throws -> APICategory {
        try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/delegation", method: "PUT", token: token, body: APICategoryDelegationUpdate(delegatedUserID: delegatedUserID))
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

    public func updateTransaction(
        budgetID: String,
        transactionID: String,
        transaction: APITransactionCreate,
        token: String
    ) async throws -> APITransaction {
        try await send(
            path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)",
            method: "PUT",
            token: token,
            body: transaction
        )
    }

    public func deleteTransaction(budgetID: String, transactionID: String, token: String) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)",
            method: "DELETE",
            token: token
        )
    }

    public func createTransfer(budgetID: String, transfer: APITransferCreate, token: String) async throws -> APITransferResponse {
        try await send(path: "api/v1/budgets/\(budgetID)/transfers", method: "POST", token: token, body: transfer)
    }

    public func reconcileAccount(budgetID: String, accountID: String, request: APIReconcileRequest, token: String) async throws -> APIReconcileResponse {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/reconcile", method: "POST", token: token, body: request)
    }

    public func updateAssignment(
        budgetID: String,
        categoryID: String,
        month: String,
        assignedMinor: Int64,
        expectedAllocationVersion: Int,
        token: String
    ) async throws -> APIAssignment {
        try await send(
            path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/assignment",
            method: "PUT",
            token: token,
            body: APIAssignmentUpdate(
                month: month,
                assignedMinor: assignedMinor,
                expectedAllocationVersion: expectedAllocationVersion
            )
        )
    }

    public func transferAllocation(
        budgetID: String,
        transfer: APIAllocationTransferCreate,
        token: String
    ) async throws -> APIAllocationOperation {
        try await send(
            path: "api/v1/budgets/\(budgetID)/allocation-transfers",
            method: "POST",
            token: token,
            body: transfer
        )
    }

    public func monthSummary(
        budgetID: String,
        month: String,
        token: String
    ) async throws -> APIMonthSummary {
        try await send(path: "api/v1/budgets/\(budgetID)/months/\(month)", token: token)
    }

    public func financialRequests(
        budgetID: String,
        token: String
    ) async throws -> [APIFinancialRequest] {
        try await send(path: "api/v1/budgets/\(budgetID)/requests", token: token)
    }

    public func createFinancialRequest(
        budgetID: String,
        request: APIFinancialRequestCreate,
        token: String
    ) async throws -> APIFinancialRequest {
        try await send(
            path: "api/v1/budgets/\(budgetID)/requests",
            method: "POST",
            token: token,
            body: request
        )
    }

    public func decideFinancialRequest(budgetID: String, requestID: String, decision: APIFinancialRequestDecision, token: String) async throws -> APIFinancialRequest {
        try await send(path: "api/v1/budgets/\(budgetID)/requests/\(requestID)/decision", method: "POST", token: token, body: decision)
    }

    public func cancelFinancialRequest(budgetID: String, requestID: String, expectedVersion: Int, note: String = "", token: String) async throws -> APIFinancialRequest {
        try await send(path: "api/v1/budgets/\(budgetID)/requests/\(requestID)/cancel", method: "POST", token: token, body: APIFinancialRequestCancel(expectedRequestVersion: expectedVersion, note: note))
    }

    public func allowancePlans(
        budgetID: String,
        token: String
    ) async throws -> [APIAllowancePlan] {
        try await send(path: "api/v1/budgets/\(budgetID)/allowances", token: token)
    }

    public func forecast(budgetID: String, through: String, token: String) async throws -> APIForecast {
        try await send(path: "api/v1/budgets/\(budgetID)/forecast", queryItems: [URLQueryItem(name: "through", value: through)], token: token)
    }

    public func spendingReport(
        budgetID: String,
        startDate: String,
        endDate: String,
        accountIDs: [String] = [],
        categoryIDs: [String] = [],
        categoryGroups: [String] = [],
        memberIDs: [String] = [],
        payees: [String] = [],
        transactionType: String? = nil,
        cleared: Bool? = nil,
        includeTracking: Bool = false,
        token: String
    ) async throws -> APISpendingReport {
        var query = [URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate)]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        query += categoryIDs.map { URLQueryItem(name: "category_id", value: $0) }
        query += categoryGroups.map { URLQueryItem(name: "category_group", value: $0) }
        query += memberIDs.map { URLQueryItem(name: "member_id", value: $0) }
        query += payees.map { URLQueryItem(name: "payee", value: $0) }
        if let transactionType { query.append(URLQueryItem(name: "transaction_type", value: transactionType)) }
        if let cleared { query.append(URLQueryItem(name: "cleared", value: String(cleared))) }
        if includeTracking { query.append(URLQueryItem(name: "include_tracking", value: "true")) }
        return try await send(
            path: "api/v1/budgets/\(budgetID)/reports/spending",
            queryItems: query,
            token: token
        )
    }

    public func incomeSpendingReport(
        budgetID: String,
        startDate: String,
        endDate: String,
        accountIDs: [String] = [],
        memberIDs: [String] = [],
        payees: [String] = [],
        cleared: Bool? = nil,
        includeTracking: Bool = false,
        token: String
    ) async throws -> APIIncomeSpendingReport {
        var query = [URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate)]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        query += memberIDs.map { URLQueryItem(name: "member_id", value: $0) }
        query += payees.map { URLQueryItem(name: "payee", value: $0) }
        if let cleared { query.append(URLQueryItem(name: "cleared", value: String(cleared))) }
        if includeTracking { query.append(URLQueryItem(name: "include_tracking", value: "true")) }
        return try await send(
            path: "api/v1/budgets/\(budgetID)/reports/income-spending",
            queryItems: query,
            token: token
        )
    }

    public func delegatedBudget(budgetID: String, token: String) async throws -> APIDelegatedBudget {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets/me", token: token)
    }

    public func delegatedBudgets(budgetID: String, token: String) async throws -> [APIDelegatedBudget] {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets", token: token)
    }

    public func updateDelegatedBudget(budgetID: String, userID: String, policy: APIDelegatedBudgetUpsert, token: String) async throws -> APIDelegatedBudget {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets/\(userID)", method: "PUT", token: token, body: policy)
    }

    public func smartFundingPreview(budgetID: String, month: String, token: String) async throws -> APISmartFundingPreview {
        try await send(path: "api/v1/budgets/\(budgetID)/smart-funding/\(month)", token: token)
    }

    public func commitSmartFunding(budgetID: String, month: String, expectedAllocationVersion: Int, token: String) async throws -> APIAllocationOperation {
        try await send(
            path: "api/v1/budgets/\(budgetID)/smart-funding", method: "POST", token: token,
            body: APISmartFundingCommit(month: month, expectedAllocationVersion: expectedAllocationVersion)
        )
    }

    private func send<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        token: String? = nil
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw APIClientError.invalidServerURL }
        return try await send(url: url, method: "GET", token: token, bodyData: nil)
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
        return try await send(url: url, method: method, token: token, bodyData: bodyData)
    }

    private func send<Response: Decodable>(
        url: URL,
        method: String,
        token: String?,
        bodyData: Data?
    ) async throws -> Response {
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
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
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

private struct EmptyResponse: Decodable {}
