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

    public func bootstrapStatus() async throws -> APIBootstrapStatus {
        try await send(path: "api/v1/bootstrap/status")
    }

    public func login(email: String, password: String, deviceName: String? = nil) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/login",
            method: "POST",
            body: LoginRequest(email: email, password: password, deviceName: deviceName)
        )
    }

    public func createPairingCode(token: String) async throws -> APIPairingCode {
        try await send(path: "api/v1/auth/pairing-code", method: "POST", token: token)
    }

    public func redeemPairingCode(_ code: String, deviceName: String) async throws -> APIAuthTokens {
        try await send(
            path: "api/v1/auth/pair",
            method: "POST",
            body: APIPairingRedeemRequest(code: code, deviceName: deviceName)
        )
    }

    public func deviceSessions(token: String) async throws -> [APIDeviceSession] {
        try await send(path: "api/v1/auth/sessions", token: token)
    }

    public func revokeDeviceSession(_ sessionID: String, token: String) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/auth/sessions/\(sessionID)", method: "DELETE", token: token
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

    public func householdInvitations(householdID: String, token: String) async throws -> [APIInvitationSummary] {
        try await send(path: "api/v1/households/\(householdID)/invitations", token: token)
    }

    public func createHouseholdInvitation(householdID: String, value: APIInvitationCreate, token: String) async throws -> APIInvitationSecret {
        try await send(path: "api/v1/households/\(householdID)/invitations", method: "POST", token: token, body: value)
    }

    public func resendHouseholdInvitation(householdID: String, invitationID: String, token: String) async throws -> APIInvitationSecret {
        try await send(path: "api/v1/households/\(householdID)/invitations/\(invitationID)/resend", method: "POST", token: token)
    }

    public func cancelHouseholdInvitation(householdID: String, invitationID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/households/\(householdID)/invitations/\(invitationID)", method: "DELETE", token: token)
    }

    public func removeHouseholdMember(householdID: String, userID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/households/\(householdID)/members/\(userID)", method: "DELETE", token: token)
    }

    public func householdAccessEvents(householdID: String, limit: Int = 200, offset: Int = 0, token: String) async throws -> [APIHouseholdAccessEvent] {
        try await send(
            path: "api/v1/households/\(householdID)/access-events",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            token: token
        )
    }

    public func accessProfile(budgetID: String, userID: String, token: String) async throws -> APIAccessProfile {
        try await send(path: "api/v1/budgets/\(budgetID)/access/\(userID)", token: token)
    }

    public func updateAccessProfile(budgetID: String, userID: String, profile: APIAccessProfileUpsert, token: String) async throws -> APIAccessProfile {
        try await send(path: "api/v1/budgets/\(budgetID)/access/\(userID)", method: "PUT", token: token, body: profile)
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

    public func accountBalance(budgetID: String, accountID: String, throughDate: String? = nil, token: String) async throws -> APIAccountBalance {
        let observation: APIAccountBalance = try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/balance",
                       queryItems: throughDate.map { [.init(name: "through_date", value: $0)] } ?? [], token: token)
        if let throughDate, observation.throughDate != throughDate || observation.accountID != accountID {
            throw APIClientError.server(status: 409, message: "Update the server to support date-specific reconciliation balances, then recheck the balance.")
        }
        return observation
    }

    public func reconciliationObservation(budgetID: String, accountID: String, throughDate: String, token: String) async throws -> APIReconciliationObservation {
        let value: APIReconciliationObservation = try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/reconciliation-observation",
            queryItems: [.init(name: "through_date", value: throughDate)], token: token)
        guard value.accountID == accountID, value.throughDate == throughDate,
              value.reviewRevision.hasPrefix("v1:"), value.reviewRevision.count == 67,
              value.reviewRevision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw APIClientError.server(status: 409, message: "Recheck reconciliation: the server returned a different or invalid review observation.")
        }
        return value
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

    public func updateAccount(
        budgetID: String,
        accountID: String,
        account: APIAccountUpdate,
        token: String
    ) async throws -> APIAccount {
        try await send(
            path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)",
            method: "PATCH",
            token: token,
            body: account
        )
    }

    public func accountHistory(
        budgetID: String, accountID: String, limit: Int = 50, offset: Int = 0, token: String
    ) async throws -> [APIAccountRevision] {
        try await send(
            path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/history",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ], token: token
        )
    }

    public func categoryHistory(
        budgetID: String, categoryID: String, limit: Int = 50, offset: Int = 0, token: String
    ) async throws -> [APIBudgetStructureRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/history",
                       queryItems: [.init(name: "limit", value: String(limit)),
                                    .init(name: "offset", value: String(offset))], token: token)
    }

    public func categoryGroupHistory(
        budgetID: String, groupID: String, limit: Int = 50, offset: Int = 0, token: String
    ) async throws -> [APIBudgetStructureRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/category-groups/\(groupID)/history",
                       queryItems: [.init(name: "limit", value: String(limit)),
                                    .init(name: "offset", value: String(offset))], token: token)
    }

    public func payeeHistory(
        budgetID: String, payeeID: String, limit: Int = 50, offset: Int = 0, token: String
    ) async throws -> [APIPayeeRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/payees/\(payeeID)/history",
                       queryItems: [.init(name: "limit", value: String(limit)),
                                    .init(name: "offset", value: String(offset))], token: token)
    }

    public func accountDebtTerms(budgetID: String, accountID: String, token: String) async throws -> APIAccountDebtTerms? {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/debt-terms", token: token)
    }

    public func updateAccountDebtTerms(budgetID: String, accountID: String, terms: APIAccountDebtTermsUpsert, token: String) async throws -> APIAccountDebtTerms {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/debt-terms", method: "PUT", token: token, body: terms)
    }

    public func deleteAccountDebtTerms(budgetID: String, accountID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/debt-terms", method: "DELETE", token: token)
    }

    public func accountDebtTermsHistory(
        budgetID: String, accountID: String, limit: Int = 50, offset: Int = 0, token: String
    ) async throws -> [APIAccountDebtTermsRevision] {
        try await send(
            path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/debt-terms/history",
            queryItems: [.init(name: "limit", value: String(limit)),
                         .init(name: "offset", value: String(offset))], token: token
        )
    }

    public func deleteBudget(budgetID: String, confirmationName: String, token: String) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/budgets/\(budgetID)", method: "DELETE", token: token,
            body: APIBudgetDeleteConfirmation(confirmationName: confirmationName)
        )
    }

    public func categoryGroups(budgetID: String, token: String) async throws -> [APICategoryGroup] {
        try await send(path: "api/v1/budgets/\(budgetID)/category-groups", token: token)
    }

    public func allocationOperations(budgetID: String, token: String) async throws -> [APIAllocationOperation] {
        try await send(path: "api/v1/budgets/\(budgetID)/allocations", token: token)
    }

    public func allocationOperationsPage(budgetID: String, limit: Int = 50, cursor: String? = nil, token: String) async throws -> APIAllocationOperationPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(
            path: "api/v1/budgets/\(budgetID)/allocations/page",
            queryItems: queryItems,
            token: token
        )
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
    public func updateCategoryGroup(budgetID: String, groupID: String, group: APICategoryGroupUpdate, token: String) async throws -> APICategoryGroup { try await send(path: "api/v1/budgets/\(budgetID)/category-groups/\(groupID)", method: "PUT", token: token, body: group) }
    public func deleteCategoryGroup(budgetID: String, groupID: String, token: String) async throws { let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/category-groups/\(groupID)", method: "DELETE", token: token) }
    public func reorderCategoryGroups(budgetID: String, orderedIDs: [String], token: String) async throws -> [APICategoryGroup] { try await send(path: "api/v1/budgets/\(budgetID)/category-group-order", method: "PUT", token: token, body: APIOrderedIDsUpdate(orderedIDs: orderedIDs)) }
    public func reorderCategories(budgetID: String, groupID: String, orderedIDs: [String], token: String) async throws -> [APICategory] { try await send(path: "api/v1/budgets/\(budgetID)/category-order/\(groupID)", method: "PUT", token: token, body: APIOrderedIDsUpdate(orderedIDs: orderedIDs)) }

    public func transactions(budgetID: String, token: String) async throws -> [APITransaction] {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions", token: token)
    }

    public func searchTransactions(budgetID: String, query: APITransactionQuery, token: String) async throws -> APITransactionPage {
        var items = [URLQueryItem(name: "sort", value: query.sort), URLQueryItem(name: "limit", value: String(query.limit))]
        if !query.search.isEmpty { items.append(URLQueryItem(name: "q", value: query.search)) }
        items += query.accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        items += query.categoryIDs.map { URLQueryItem(name: "category_id", value: $0) }
        items += query.payeeIDs.map { URLQueryItem(name: "payee_id", value: $0) }
        if let value = query.startDate { items.append(URLQueryItem(name: "start_date", value: value)) }
        if let value = query.endDate { items.append(URLQueryItem(name: "end_date", value: value)) }
        if let value = query.minimumAmountMinor { items.append(URLQueryItem(name: "minimum_amount_minor", value: String(value))) }
        if let value = query.maximumAmountMinor { items.append(URLQueryItem(name: "maximum_amount_minor", value: String(value))) }
        if let value = query.transactionType { items.append(URLQueryItem(name: "transaction_type", value: value)) }
        items += query.lifecycleStatuses.map { URLQueryItem(name: "lifecycle_status", value: $0) }
        if let value = query.cleared { items.append(URLQueryItem(name: "cleared", value: String(value))) }
        if let value = query.reconciled { items.append(URLQueryItem(name: "reconciled", value: String(value))) }
        items += query.flags.map { URLQueryItem(name: "flag", value: $0) }
        items += query.tags.map { URLQueryItem(name: "tag", value: $0) }
        items += query.actorUserIDs.map { URLQueryItem(name: "actor_user_id", value: $0) }
        if let value = query.isTransfer { items.append(URLQueryItem(name: "is_transfer", value: String(value))) }
        if let value = query.isScheduledRealization { items.append(URLQueryItem(name: "is_scheduled_realization", value: String(value))) }
        if let value = query.cursor { items.append(URLQueryItem(name: "cursor", value: value)) }
        return try await send(path: "api/v1/budgets/\(budgetID)/transactions/search", queryItems: items, token: token)
    }

    public func duplicateTransaction(budgetID: String, transactionID: String, occurredOn: String, token: String) async throws -> APITransaction {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/duplicate", method: "POST", token: token, body: APITransactionDuplicate(occurredOn: occurredOn))
    }

    public func voidTransaction(budgetID: String, transactionID: String, reason: String, token: String) async throws -> APITransaction {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/void", method: "POST", token: token, body: APITransactionVoid(reason: reason))
    }

    public func createScheduleFromTransaction(budgetID: String, transactionID: String, request: APITransactionSchedule, token: String) async throws -> APIScheduledTransaction {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/schedule", method: "POST", token: token, body: request)
    }

    public func transactionAttachments(budgetID: String, transactionID: String, token: String) async throws -> [APITransactionAttachment] {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/attachments", token: token)
    }

    public func transactionHistory(budgetID: String, transactionID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APITransactionChange] {
        try await send(
            path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/history",
            queryItems: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))],
            token: token
        )
    }

    public func recentTransactionChanges(budgetID: String, limit: Int = 5, token: String) async throws -> [APITransactionChange] {
        try await send(
            path: "api/v1/budgets/\(budgetID)/transaction-changes",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))],
            token: token
        )
    }

    public func uploadTransactionAttachment(budgetID: String, transactionID: String, filename: String, contentType: String, data: Data, token: String) async throws -> APITransactionAttachment {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/attachments"))
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Attachment-Filename")
        request.setValue(contentType, forHTTPHeaderField: "X-Attachment-Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        guard let value = try? JSONDecoder().decode(APITransactionAttachment.self, from: body) else { throw APIClientError.invalidResponse }
        return value
    }

    public func downloadTransactionAttachment(budgetID: String, transactionID: String, attachmentID: String, token: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/attachments/\(attachmentID)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        return body
    }

    public func detachTransactionAttachment(budgetID: String, transactionID: String, attachmentID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/transactions/\(transactionID)/attachments/\(attachmentID)", method: "DELETE", token: token)
    }

    public func bulkUpdateTransactions(budgetID: String, update: APITransactionBulkUpdate, token: String) async throws -> [APITransaction] {
        try await send(path: "api/v1/budgets/\(budgetID)/transactions/bulk", method: "POST", token: token, body: update)
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
    public func deleteCategory(budgetID: String, categoryID: String, token: String) async throws { let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)", method: "DELETE", token: token) }
    public func favoriteCategory(budgetID: String, categoryID: String, sortOrder: Int, token: String) async throws -> APICategory { try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/favorite", method: "PUT", token: token, body: APICategoryFavoriteUpsert(sortOrder: sortOrder)) }
    public func unfavoriteCategory(budgetID: String, categoryID: String, token: String) async throws { let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/favorite", method: "DELETE", token: token) }

    public func updateCategoryDelegation(budgetID: String, categoryID: String, delegatedUserID: String?, token: String) async throws -> APICategory {
        try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/delegation", method: "PUT", token: token, body: APICategoryDelegationUpdate(delegatedUserID: delegatedUserID))
    }

    public func categoryTarget(budgetID: String, categoryID: String, token: String) async throws -> APICategoryTarget? { try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/target", token: token) }
    public func categoryTargetHistory(budgetID: String, categoryID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APICategoryTargetRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/target/history", queryItems: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))], token: token)
    }
    public func upsertCategoryTarget(budgetID: String, categoryID: String, target: APICategoryTargetUpsert, token: String) async throws -> APICategoryTarget { try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/target", method: "PUT", token: token, body: target) }
    public func deleteCategoryTarget(budgetID: String, categoryID: String, token: String) async throws { let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/target", method: "DELETE", token: token) }
    public func setCategoryTargetSnoozed(budgetID: String, categoryID: String, month: String, isSnoozed: Bool, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/target/snooze/\(month)", method: "PUT", token: token, body: APITargetSnoozeUpdate(isSnoozed: isSnoozed))
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

    public func payees(budgetID: String, includeArchived: Bool = false, token: String) async throws -> [APIPayee] {
        try await send(
            path: "api/v1/budgets/\(budgetID)/payees",
            queryItems: [URLQueryItem(name: "include_archived", value: String(includeArchived))],
            token: token
        )
    }

    public func searchPayees(budgetID: String, query: String = "", includeArchived: Bool = false, limit: Int = 20, cursor: String? = nil, token: String) async throws -> APIPayeePage {
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "include_archived", value: String(includeArchived)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/budgets/\(budgetID)/payees/search", queryItems: queryItems, token: token)
    }

    public func createPayee(budgetID: String, payee: APIPayeeCreate, token: String) async throws -> APIPayee {
        try await send(path: "api/v1/budgets/\(budgetID)/payees", method: "POST", token: token, body: payee)
    }

    public func updatePayee(budgetID: String, payeeID: String, payee: APIPayeeUpdate, token: String) async throws -> APIPayee {
        try await send(path: "api/v1/budgets/\(budgetID)/payees/\(payeeID)", method: "PUT", token: token, body: payee)
    }

    public func mergePayee(budgetID: String, payeeID: String, destinationPayeeID: String, token: String) async throws -> APIPayee {
        try await send(path: "api/v1/budgets/\(budgetID)/payees/\(payeeID)/merge", method: "POST", token: token, body: APIPayeeMerge(destinationPayeeID: destinationPayeeID))
    }

    public func createPayeeAlias(budgetID: String, payeeID: String, displayName: String, token: String) async throws -> APIPayeeAlias {
        try await send(path: "api/v1/budgets/\(budgetID)/payees/\(payeeID)/aliases", method: "POST", token: token, body: APIPayeeAliasCreate(displayName: displayName))
    }

    public func deletePayeeAlias(budgetID: String, payeeID: String, aliasID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/payees/\(payeeID)/aliases/\(aliasID)", method: "DELETE", token: token)
    }

    public func createTransfer(budgetID: String, transfer: APITransferCreate, token: String) async throws -> APITransferResponse {
        try await send(path: "api/v1/budgets/\(budgetID)/transfers", method: "POST", token: token, body: transfer)
    }

    public func updateTransfer(budgetID: String, transferID: String, transfer: APITransferCreate, token: String) async throws -> APITransferResponse {
        try await send(path: "api/v1/budgets/\(budgetID)/transfers/\(transferID)", method: "PUT", token: token, body: transfer)
    }

    public func deleteTransfer(budgetID: String, transferID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/transfers/\(transferID)", method: "DELETE", token: token)
    }

    public func reconcileAccount(budgetID: String, accountID: String, request: APIReconcileRequest, token: String) async throws -> APIReconcileResponse {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/reconcile", method: "POST", token: token, body: request)
    }

    public func reconciliationHistory(budgetID: String, accountID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APIReconciliationHistory] {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/reconciliations", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)),
        ], token: token)
    }

    public func recentReconciliationHistory(budgetID: String, limit: Int = 5, token: String) async throws -> [APIReconciliationHistory] {
        try await send(path: "api/v1/budgets/\(budgetID)/reconciliations", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
        ], token: token)
    }

    public func stageStatementImport(budgetID: String, accountID: String, data: Data,
                                     mapping: APIStatementImportMapping, token: String) async throws -> APIStatementImport {
        guard data.count <= 10 * 1024 * 1024 else {
            throw APIClientError.server(status: 422, message: "Statement files must be 10 MB or smaller.")
        }
        var components = URLComponents(url: baseURL.appending(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "match_window_days", value: "2")]
        guard let url = components?.url else { throw APIClientError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let headers: [(String, String?)] = [
            ("X-Statement-Format", mapping.sourceFormat), ("X-Statement-Currency", mapping.currencyCode),
            ("X-CSV-Date-Column", mapping.dateColumn), ("X-CSV-Amount-Column", mapping.amountColumn),
            ("X-CSV-Payee-Column", mapping.payeeColumn), ("X-CSV-Memo-Column", mapping.memoColumn),
            ("X-CSV-Debit-Column", mapping.debitColumn), ("X-CSV-Credit-Column", mapping.creditColumn),
            ("X-Statement-Date-Order", mapping.dateOrder), ("X-CSV-Delimiter", mapping.delimiter),
            ("X-CSV-Number-Format", mapping.numberFormat),
        ]
        for (name, value) in headers { if let value { request.setValue(value, forHTTPHeaderField: name) } }
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        do { return try JSONDecoder().decode(APIStatementImport.self, from: body) }
        catch { throw APIClientError.invalidResponse }
    }

    public func statementImports(budgetID: String, accountID: String, limit: Int = 25,
                                 offset: Int = 0, token: String) async throws -> APIStatementImportList {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports",
                       queryItems: [URLQueryItem(name: "limit", value: String(limit)),
                                    URLQueryItem(name: "offset", value: String(offset))], token: token)
    }

    public func statementImport(budgetID: String, accountID: String, batchID: String,
                                token: String) async throws -> APIStatementImport {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports/\(batchID)",
                       token: token)
    }

    public func approveStatementImport(budgetID: String, accountID: String, batchID: String,
                                       approval: APIStatementImportApprove, token: String) async throws -> APIStatementImport {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports/\(batchID)/approve",
                       method: "POST", token: token, body: approval)
    }

    public func cancelStatementImport(budgetID: String, accountID: String, batchID: String,
                                      expectedVersion: Int, token: String) async throws -> APIStatementImport {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports/\(batchID)/cancel",
                       method: "POST", token: token,
                       body: APIStatementImportCancel(expectedVersion: expectedVersion))
    }

    public func undoStatementImport(budgetID: String, accountID: String, batchID: String,
                                    expectedVersion: Int, token: String) async throws -> APIStatementImport {
        try await send(path: "api/v1/budgets/\(budgetID)/accounts/\(accountID)/statement-imports/\(batchID)/undo",
                       method: "POST", token: token,
                       body: APIStatementImportUndo(expectedVersion: expectedVersion))
    }

    public func updateAssignment(
        budgetID: String,
        categoryID: String,
        month: String,
        assignedMinor: Int64,
        expectedAllocationVersion: Int,
        mutationOperationID: String? = nil,
        token: String
    ) async throws -> APIAssignment {
        try await send(
            path: "api/v1/budgets/\(budgetID)/categories/\(categoryID)/assignment",
            method: "PUT",
            token: token,
            body: APIAssignmentUpdate(
                month: month,
                assignedMinor: assignedMinor,
                expectedAllocationVersion: expectedAllocationVersion,
                mutationOperationID: mutationOperationID
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

    public func reviseFinancialRequest(budgetID: String, requestID: String, value: APIFinancialRequestCreate, expectedVersion: Int, token: String) async throws -> APIFinancialRequest {
        try await send(path: "api/v1/budgets/\(budgetID)/requests/\(requestID)/revise", method: "POST", token: token, body: APIFinancialRequestRevision(requestType: value.requestType, destinationCategoryID: value.destinationCategoryID, requestedAmountMinor: value.requestedAmountMinor, reason: value.reason, expectedRequestVersion: expectedVersion))
    }

    public func allowancePlans(
        budgetID: String,
        includeInactive: Bool = false,
        token: String
    ) async throws -> [APIAllowancePlan] {
        try await send(path: "api/v1/budgets/\(budgetID)/allowances", queryItems: includeInactive ? [URLQueryItem(name: "include_inactive", value: "true")] : [], token: token)
    }

    public func createAllowancePlan(budgetID: String, value: APIAllowancePlanCreate, token: String) async throws -> APIAllowancePlan { try await send(path: "api/v1/budgets/\(budgetID)/allowances", method: "POST", token: token, body: value) }
    public func setAllowancePlanActive(budgetID: String, planID: String, isActive: Bool, token: String) async throws -> APIAllowancePlan { try await send(path: "api/v1/budgets/\(budgetID)/allowances/\(planID)/status", method: "PATCH", token: token, body: APIAllowanceStatusUpdate(isActive: isActive)) }
    public func issueAllowance(budgetID: String, planID: String, issueDate: String, expectedAllocationVersion: Int, token: String) async throws -> APIAllowanceIssuance { try await send(path: "api/v1/budgets/\(budgetID)/allowances/\(planID)/issue", method: "POST", token: token, body: APIAllowanceIssueRequest(issueDate: issueDate, expectedAllocationVersion: expectedAllocationVersion)) }
    public func allowanceIssuances(budgetID: String, planID: String, token: String, limit: Int? = nil, offset: Int = 0) async throws -> [APIAllowanceIssuance] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if offset != 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        return try await send(path: "api/v1/budgets/\(budgetID)/allowances/\(planID)/issuances", queryItems: query, token: token)
    }
    public func allowancePlanHistory(budgetID: String, planID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APIAllowancePlanRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/allowances/\(planID)/history", queryItems: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))], token: token)
    }

    public func forecast(budgetID: String, through: String, token: String) async throws -> APIForecast {
        try await send(path: "api/v1/budgets/\(budgetID)/forecast", queryItems: [URLQueryItem(name: "through", value: through)], token: token)
    }

    public func scheduledTransactions(budgetID: String, includeInactive: Bool = false, token: String) async throws -> [APIScheduledTransaction] {
        try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions", queryItems: includeInactive ? [URLQueryItem(name: "include_inactive", value: "true")] : [], token: token)
    }
    public func scheduledTransactionHistory(budgetID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APIScheduledTransactionRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions/history", queryItems: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))], token: token)
    }
    public func createScheduledTransaction(budgetID: String, schedule: APIScheduledTransactionCreate, token: String) async throws -> APIScheduledTransaction {
        try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions", method: "POST", token: token, body: schedule)
    }
    public func updateScheduledTransaction(budgetID: String, scheduleID: String, schedule: APIScheduledTransactionCreate, token: String) async throws -> APIScheduledTransaction {
        try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions/\(scheduleID)", method: "PUT", token: token, body: schedule)
    }
    public func deleteScheduledTransaction(budgetID: String, scheduleID: String, token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions/\(scheduleID)", method: "DELETE", token: token)
    }
    public func realizeScheduledTransaction(budgetID: String, scheduleID: String, token: String) async throws -> APIScheduledRealization {
        try await send(path: "api/v1/budgets/\(budgetID)/scheduled-transactions/\(scheduleID)/realize", method: "POST", token: token)
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
        reconciled: Bool? = nil,
        flags: [String] = [],
        tags: [String] = [],
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
        if let reconciled { query.append(URLQueryItem(name: "reconciled", value: String(reconciled))) }
        query += flags.map { URLQueryItem(name: "flag", value: $0) }
        query += tags.map { URLQueryItem(name: "tag", value: $0) }
        if includeTracking { query.append(URLQueryItem(name: "include_tracking", value: "true")) }
        return try await send(
            path: "api/v1/budgets/\(budgetID)/reports/spending",
            queryItems: query,
            token: token
        )
    }

    public func spendingTrendsReport(
        budgetID: String, startDate: String, endDate: String, dimension: String,
        accountIDs: [String] = [], categoryIDs: [String] = [], categoryGroups: [String] = [],
        memberIDs: [String] = [], payees: [String] = [], transactionType: String? = nil, cleared: Bool? = nil,
        reconciled: Bool? = nil, flags: [String] = [], tags: [String] = [],
        includeTracking: Bool = false, token: String
    ) async throws -> APISpendingTrendsReport {
        var query = [
            URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "dimension", value: dimension),
        ]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        query += categoryIDs.map { URLQueryItem(name: "category_id", value: $0) }
        query += categoryGroups.map { URLQueryItem(name: "category_group", value: $0) }
        query += memberIDs.map { URLQueryItem(name: "member_id", value: $0) }
        query += payees.map { URLQueryItem(name: "payee", value: $0) }
        if let transactionType { query.append(URLQueryItem(name: "transaction_type", value: transactionType)) }
        if let cleared { query.append(URLQueryItem(name: "cleared", value: String(cleared))) }
        if let reconciled { query.append(URLQueryItem(name: "reconciled", value: String(reconciled))) }
        query += flags.map { URLQueryItem(name: "flag", value: $0) }
        query += tags.map { URLQueryItem(name: "tag", value: $0) }
        if includeTracking { query.append(URLQueryItem(name: "include_tracking", value: "true")) }
        return try await send(path: "api/v1/budgets/\(budgetID)/reports/spending-trends", queryItems: query, token: token)
    }

    public func incomeSpendingReport(
        budgetID: String,
        startDate: String,
        endDate: String,
        accountIDs: [String] = [],
        memberIDs: [String] = [],
        payees: [String] = [],
        cleared: Bool? = nil,
        reconciled: Bool? = nil,
        flags: [String] = [],
        tags: [String] = [],
        includeTracking: Bool = false,
        token: String
    ) async throws -> APIIncomeSpendingReport {
        var query = [URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate)]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        query += memberIDs.map { URLQueryItem(name: "member_id", value: $0) }
        query += payees.map { URLQueryItem(name: "payee", value: $0) }
        if let cleared { query.append(URLQueryItem(name: "cleared", value: String(cleared))) }
        if let reconciled { query.append(URLQueryItem(name: "reconciled", value: String(reconciled))) }
        query += flags.map { URLQueryItem(name: "flag", value: $0) }
        query += tags.map { URLQueryItem(name: "tag", value: $0) }
        if includeTracking { query.append(URLQueryItem(name: "include_tracking", value: "true")) }
        return try await send(
            path: "api/v1/budgets/\(budgetID)/reports/income-spending",
            queryItems: query,
            token: token
        )
    }

    public func netWorthReport(
        budgetID: String,
        startDate: String,
        endDate: String,
        accountIDs: [String] = [],
        includeTracking: Bool = true,
        token: String
    ) async throws -> APINetWorthReport {
        var query = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "include_tracking", value: String(includeTracking)),
        ]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        return try await send(path: "api/v1/budgets/\(budgetID)/reports/net-worth", queryItems: query, token: token)
    }

    public func insightsSummary(
        budgetID: String, startDate: String, endDate: String,
        accountIDs: [String] = [], memberIDs: [String] = [], payees: [String] = [],
        cleared: Bool? = nil, reconciled: Bool? = nil, flags: [String] = [], tags: [String] = [],
        includeTracking: Bool = false, token: String
    ) async throws -> APIInsightsSummary {
        var query = [URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate), URLQueryItem(name: "include_tracking", value: String(includeTracking))]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        query += memberIDs.map { URLQueryItem(name: "member_id", value: $0) }
        query += payees.map { URLQueryItem(name: "payee", value: $0) }
        query += flags.map { URLQueryItem(name: "flag", value: $0) }
        query += tags.map { URLQueryItem(name: "tag", value: $0) }
        if let cleared { query.append(URLQueryItem(name: "cleared", value: String(cleared))) }
        if let reconciled { query.append(URLQueryItem(name: "reconciled", value: String(reconciled))) }
        return try await send(path: "api/v1/budgets/\(budgetID)/reports/summary", queryItems: query, token: token)
    }

    public func debtReport(
        budgetID: String,
        startDate: String,
        endDate: String,
        accountIDs: [String] = [],
        token: String
    ) async throws -> APIDebtReport {
        var query = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
        ]
        query += accountIDs.map { URLQueryItem(name: "account_id", value: $0) }
        return try await send(path: "api/v1/budgets/\(budgetID)/reports/debt", queryItems: query, token: token)
    }

    public func debtStrategyProjection(
        budgetID: String,
        request: APIDebtStrategyProjectionRequest,
        token: String
    ) async throws -> APIDebtStrategyProjection {
        try await send(
            path: "api/v1/budgets/\(budgetID)/debt-strategy-projection",
            method: "POST",
            token: token,
            body: request
        )
    }

    public func debtPayoffPlan(budgetID: String, token: String) async throws -> APIDebtPayoffPlan? {
        try await send(path: "api/v1/budgets/\(budgetID)/debt-payoff-plan", token: token)
    }

    public func debtPayoffPlanHistory(budgetID: String, limit: Int = 50, offset: Int = 0,
                                     token: String) async throws -> [APIDebtPayoffPlanRevision] {
        guard (1...100).contains(limit), offset >= 0 else {
            throw APIClientError.server(status: 422, message: "Choose a history page size from 1 to 100 and a nonnegative offset.")
        }
        return try await send(path: "api/v1/budgets/\(budgetID)/debt-payoff-plan/history", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)),
        ], token: token)
    }

    public func saveDebtPayoffPlan(
        budgetID: String, request: APIDebtPayoffPlanUpsert, token: String
    ) async throws -> APIDebtPayoffPlan {
        try request.validate()
        return try await send(
            path: "api/v1/budgets/\(budgetID)/debt-payoff-plan",
            method: "PUT", token: token, body: request
        )
    }

    public func deleteDebtPayoffPlan(budgetID: String, token: String) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/budgets/\(budgetID)/debt-payoff-plan", method: "DELETE", token: token
        )
    }

    public func debtCost(budgetID: String, accountIDs: [String] = [], token: String) async throws -> APIDebtCost {
        try await send(path: "api/v1/budgets/\(budgetID)/reports/debt-cost",
                       queryItems: accountIDs.map { URLQueryItem(name: "account_id", value: $0) }, token: token)
    }

    public func planPerformanceReport(budgetID: String, startDate: String, endDate: String, token: String) async throws -> APIPlanPerformanceReport {
        try await send(path: "api/v1/budgets/\(budgetID)/reports/plan-performance", queryItems: [
            URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate),
        ], token: token)
    }

    public func resilienceReport(budgetID: String, horizonDays: Int = 30, token: String) async throws -> APIResilienceReport {
        try await send(path: "api/v1/budgets/\(budgetID)/reports/resilience", queryItems: [
            URLQueryItem(name: "horizon_days", value: String(horizonDays)),
        ], token: token)
    }

    public func reportExportCSV(budgetID: String, startDate: String, endDate: String, token: String) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/budgets/\(budgetID)/reports/export.csv"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "start_date", value: startDate), URLQueryItem(name: "end_date", value: endDate)]
        guard let url = components?.url else { throw APIClientError.invalidServerURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        return body
    }

    public func budgetExportJSON(budgetID: String, token: String) async throws -> Data {
        let url = baseURL.appending(path: "api/v1/budgets/\(budgetID)/export.json")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        return body
    }

    public func delegatedBudget(budgetID: String, token: String) async throws -> APIDelegatedBudget? {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets/me", token: token)
    }

    public func delegatedBudgets(budgetID: String, token: String) async throws -> [APIDelegatedBudget] {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets", token: token)
    }

    public func updateDelegatedBudget(budgetID: String, userID: String, policy: APIDelegatedBudgetUpsert, token: String) async throws -> APIDelegatedBudget {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets/\(userID)", method: "PUT", token: token, body: policy)
    }

    public func delegatedBudgetHistory(budgetID: String, userID: String, limit: Int = 50, offset: Int = 0, token: String) async throws -> [APIDelegatedPolicyRevision] {
        try await send(path: "api/v1/budgets/\(budgetID)/delegated-budgets/\(userID)/history", queryItems: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))], token: token)
    }

    public func smartFundingPreview(budgetID: String, month: String, token: String) async throws -> APISmartFundingPreview {
        try await send(path: "api/v1/budgets/\(budgetID)/smart-funding/\(month)", token: token)
    }

    public func cashRolloverPolicy(budgetID: String, token: String) async throws -> APICashRolloverPolicyObservation {
        try await send(path: "api/v1/budgets/\(budgetID)/cash-rollover-policy", token: token)
    }

    public func selectCashRolloverPolicy(budgetID: String, selection: APICashRolloverPolicySelection, token: String) async throws -> APICashRolloverPolicyObservation {
        try await send(path: "api/v1/budgets/\(budgetID)/cash-rollover-policy", method: "PUT", token: token, body: selection)
    }

    public func cashRolloverPolicyHistory(budgetID: String, beforeVersion: Int? = nil, limit: Int = 50, token: String) async throws -> APICashRolloverPolicyHistory {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeVersion { query.append(URLQueryItem(name: "before_version", value: String(beforeVersion))) }
        return try await send(path: "api/v1/budgets/\(budgetID)/cash-rollover-policy/history", queryItems: query, token: token)
    }

    public func commitSmartFunding(budgetID: String, month: String, expectedAllocationVersion: Int, token: String) async throws -> APIAllocationOperation {
        try await send(
            path: "api/v1/budgets/\(budgetID)/smart-funding", method: "POST", token: token,
            body: APISmartFundingCommit(month: month, expectedAllocationVersion: expectedAllocationVersion)
        )
    }

    public func backupStatus(budgetID: String, token: String) async throws -> APIServerBackupStatus {
        try await send(path: "api/v1/budgets/\(budgetID)/backup-status", token: token)
    }

    public func localDeviceTransferEligibility(budgetID: String, token: String) async throws -> APILocalDeviceTransferEligibility {
        try await send(path: "api/v1/budgets/\(budgetID)/local-device-transfer-eligibility", token: token)
    }

    /// Downloads the complete point-in-time transfer projection without interpreting financial
    /// semantics in the HTTP layer. BudgetStorage owns strict decoding and candidate validation.
    public func localDeviceTransferProjectionData(budgetID: String, token: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/budgets/\(budgetID)/local-device-transfer"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        try validate(response: response, data: body)
        return body
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

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data).detail) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIClientError.server(status: http.statusCode, message: message)
        }
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
