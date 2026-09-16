import XCTest
@testable import BudgetAPI

final class APIClientTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    func testRejectsInsecureRemoteServer() {
        XCTAssertThrowsError(try APIClient(baseURL: URL(string: "http://example.com")!)) { error in
            XCTAssertEqual(error as? APIClientError, .insecureRemoteServer)
        }
    }

    func testAllowsLocalHTTPForSimulatorDevelopment() {
        XCTAssertNoThrow(try APIClient(baseURL: URL(string: "http://localhost:8080")!))
    }

    func testAccountCreateEncodesExactStartingBalanceMinorUnits() throws {
        let data = try JSONEncoder().encode(
            APIAccountCreate(
                name: "Everyday Checking",
                accountType: "checking",
                isOnBudget: true,
                startingBalanceMinor: 123456
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["starting_balance_minor"] as? Int, 123456)
        XCTAssertEqual(json["is_on_budget"] as? Bool, true)
    }

    func testAccountMetadataUpdateCannotCarryBalanceOrBudgetTreatment() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1")
            let body = try requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json as NSDictionary, ["name": "Savings", "account_type": "savings"] as NSDictionary)
            let response = Data(#"{"id":"a1","budget_id":"b1","name":"Savings","account_type":"savings","is_on_budget":true,"is_closed":false,"reconciled_balance_minor":null,"payment_category_id":null}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let account = try await client.updateAccount(budgetID: "b1", accountID: "a1", account: .init(name: "Savings", accountType: "savings"), token: "secret")
        XCTAssertEqual(account.name, "Savings")
        XCTAssertTrue(account.isOnBudget)
    }

    func testCategoryFavoriteUsesUserScopedMetadataEndpoints() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/categories/c1/favorite")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            if request.httpMethod == "PUT" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["sort_order"] as? Int, 7)
                let body = Data(#"{"id":"c1","budget_id":"b1","group_id":"g1","name":"Groceries","sort_order":0,"is_archived":false,"system_type":null,"linked_account_id":null,"delegated_user_id":null,"is_favorite":true,"favorite_sort_order":7}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let favorite = try await client.favoriteCategory(budgetID: "b1", categoryID: "c1", sortOrder: 7, token: "secret")
        XCTAssertTrue(favorite.isFavorite)
        XCTAssertEqual(favorite.favoriteSortOrder, 7)
        try await client.unfavoriteCategory(budgetID: "b1", categoryID: "c1", token: "secret")
        XCTAssertEqual(methods, ["PUT", "DELETE"])
    }

    func testBootstrapStatusDiscoversUninitializedServerWithoutAuthentication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/bootstrap/status")
            // Discovery must not send credentials — it precedes sign in.
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = Data(#"{"initialized":false,"authentication_required":true,"api_version":"0.4.0"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let status = try await client.bootstrapStatus()

        XCTAssertEqual(status, APIBootstrapStatus(initialized: false, authenticationRequired: true, apiVersion: "0.4.0"))
    }

    func testBudgetRequestSendsBearerTokenAndDecodesPrivacyFilteredList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = Data(#"[{"id":"b1","household_id":"h1","name":"Family","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let budgets = try await client.budgets(token: "secret")

        XCTAssertEqual(budgets, [APIBudget(id: "b1", householdID: "h1", name: "Family", currencyCode: "USD")])
    }

    func testAccessProfileReadAndVersionedUpdateUseBudgetScopedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/access/u2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            if request.httpMethod == "PUT" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["expected_version"] as? Int, 41)
                XCTAssertEqual(json["restrict_accounts"] as? Bool, true)
                XCTAssertEqual(json["account_ids"] as? [String], ["a1"])
            }
            let version = request.httpMethod == "PUT" ? 42 : 41
            let body = Data("{\"budget_id\":\"b1\",\"user_id\":\"u2\",\"capabilities\":[\"view_budget\"],\"restrict_accounts\":true,\"account_ids\":[\"a1\"],\"restrict_categories\":false,\"category_ids\":[],\"grant_permission\":\"custom\",\"is_custom\":true,\"version\":\(version),\"updated_by_user_id\":\"u1\",\"updated_by_display_name\":\"Owner\",\"updated_at\":\"2026-09-16T12:00:00Z\"}".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let profile = try await client.accessProfile(budgetID: "b1", userID: "u2", token: "current-token")
        XCTAssertEqual(profile.version, 41)
        let updated = try await client.updateAccessProfile(budgetID: "b1", userID: "u2", profile: .init(capabilities: ["view_budget"], restrictAccounts: true, accountIDs: ["a1"], restrictCategories: false, categoryIDs: [], expectedVersion: profile.version), token: "current-token")
        XCTAssertEqual(updated.version, 42)
        XCTAssertEqual(methods, ["GET", "PUT"])
    }

    func testMonthSummaryUsesBudgetScopedPathAndDecodesMinorUnits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/months/2026-09-01")
            let body = Data(#"{"month":"2026-09-01","currency_code":"USD","ready_to_assign_minor":12500,"total_assigned_minor":5000,"total_overspent_minor":0,"allocation_version":3,"categories":[]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let summary = try await client.monthSummary(
            budgetID: "b1",
            month: "2026-09-01",
            token: "secret"
        )

        XCTAssertEqual(summary.readyToAssignMinor, 12500)
        XCTAssertEqual(summary.currencyCode, "USD")
        XCTAssertEqual(summary.allocationVersion, 3)
    }

    func testCreateTransactionEncodesExactMinorUnits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(json["amount_minor"] as? Int, -12345)
            XCTAssertEqual(json["category_id"] as? String, "c1")
            let response = Data(#"{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"c1","amount_minor":-12345,"occurred_on":"2026-09-04","payee_name":"Market","memo":"","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"splits":[]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let transaction = try await client.createTransaction(
            budgetID: "b1",
            transaction: APITransactionCreate(
                accountID: "a1",
                categoryID: "c1",
                amountMinor: -12345,
                occurredOn: "2026-09-04",
                payeeName: "Market"
            ),
            token: "secret"
        )

        XCTAssertEqual(transaction.amountMinor, -12345)
    }

    func testCreateTransactionCarriesCanonicalPayeeIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(json["payee_id"] as? String, "p1")
            XCTAssertEqual(json["payee_name"] as? String, "Neighborhood Market")
            let response = Data(#"{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"c1","payee_id":"p1","amount_minor":-12345,"occurred_on":"2026-09-04","payee_name":"Neighborhood Market","memo":"","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"splits":[]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let transaction = try await client.createTransaction(
            budgetID: "b1",
            transaction: APITransactionCreate(
                accountID: "a1",
                categoryID: "c1",
                payeeID: "p1",
                amountMinor: -12345,
                occurredOn: "2026-09-04",
                payeeName: "Neighborhood Market"
            ),
            token: "secret"
        )

        XCTAssertEqual(transaction.payeeID, "p1")
    }

    func testTransactionBrowserEncodesTypedFiltersAndDecodesPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(.init(name: "q", value: "market")))
            XCTAssertTrue(items.contains(.init(name: "account_id", value: "a1")))
            XCTAssertTrue(items.contains(.init(name: "category_id", value: "c1")))
            XCTAssertTrue(items.contains(.init(name: "minimum_amount_minor", value: "-5000")))
            XCTAssertTrue(items.contains(.init(name: "cleared", value: "true")))
            XCTAssertTrue(items.contains(.init(name: "lifecycle_status", value: "voided")))
            XCTAssertTrue(items.contains(.init(name: "sort", value: "amount_asc")))
            XCTAssertTrue(items.contains(.init(name: "cursor", value: "opaque")))
            let response = Data(#"{"items":[{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"c1","payee_id":"p1","amount_minor":-1200,"occurred_on":"2026-09-04","created_at":"2026-09-04T12:00:00Z","payee_name":"Market","memo":"","is_cleared":true,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"scheduled_transaction_id":null,"splits":[]}],"next_cursor":"next","total_count":2}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let page = try await client.searchTransactions(
            budgetID: "b1",
            query: .init(search: "market", accountIDs: ["a1"], categoryIDs: ["c1"], minimumAmountMinor: -5000, lifecycleStatuses: ["voided"], cleared: true, sort: "amount_asc", cursor: "opaque"),
            token: "secret"
        )
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.nextCursor, "next")
        XCTAssertEqual(page.items.first?.createdByUserID, "u1")
    }

    func testDuplicateTransactionUsesExplicitDateContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1/duplicate")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["occurred_on"] as? String, "2026-09-14")
            let response = Data(#"{"id":"t2","budget_id":"b1","account_id":"a1","category_id":"c1","payee_id":null,"amount_minor":-1200,"occurred_on":"2026-09-14","created_at":"2026-09-14T12:00:00Z","payee_name":"Market","memo":"","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"scheduled_transaction_id":null,"splits":[]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let copy = try await client.duplicateTransaction(budgetID: "b1", transactionID: "t1", occurredOn: "2026-09-14", token: "secret")
        XCTAssertEqual(copy.id, "t2")
        XCTAssertFalse(copy.isCleared)
    }

    func testVoidAndMakeRecurringUseExplicitAuditContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestNumber = 0
        MockURLProtocol.handler = { request in
            defer { requestNumber += 1 }
            if requestNumber == 0 {
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1/void")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["reason"] as? String, "Duplicate")
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"r1","account_id":"a1","category_id":"c1","payee_id":null,"amount_minor":1200,"occurred_on":"2026-09-14","payee_name":"Reversal: Market","memo":"","is_cleared":false,"is_reconciled":false,"transfer_id":null,"scheduled_transaction_id":null,"status":"reversal","reversal_of_transaction_id":"t1","splits":[]}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1/schedule")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["recurrence_unit"] as? String, "months")
            XCTAssertEqual(json["next_date"] as? String, "2026-10-14")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"s1","budget_id":"b1","account_id":"a1","destination_account_id":null,"category_id":"c1","name":"Market","amount_minor":-1200,"next_date":"2026-10-14","recurrence_unit":"months","interval_count":1,"memo":"","is_active":true,"last_realized_on":null}"#.utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let reversal = try await client.voidTransaction(budgetID: "b1", transactionID: "t1", reason: "Duplicate", token: "secret")
        XCTAssertEqual(reversal.status, "reversal")
        let schedule = try await client.createScheduleFromTransaction(budgetID: "b1", transactionID: "t1", request: .init(recurrenceUnit: "months", nextDate: "2026-10-14"), token: "secret")
        XCTAssertEqual(schedule.id, "s1")
    }

    func testAttachmentUploadUsesManagedBinaryContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1/attachments")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Attachment-Filename"), "receipt.pdf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Attachment-Content-Type"), "application/pdf")
            XCTAssertEqual(try requestBody(request), Data("%PDF-test".utf8))
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"at1","transaction_id":"t1","filename":"receipt.pdf","content_type":"application/pdf","byte_count":9,"sha256":"hash","created_at":"2026-09-14T12:00:00Z","detached_at":null}"#.utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let result = try await client.uploadTransactionAttachment(budgetID: "b1", transactionID: "t1", filename: "receipt.pdf", contentType: "application/pdf", data: Data("%PDF-test".utf8), token: "secret")
        XCTAssertEqual(result.id, "at1")
    }

    func testBulkTransactionUpdateUsesAtomicTypedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/bulk")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["transaction_ids"] as? [String], ["t1", "t2"])
            XCTAssertEqual(json["action"] as? String, "add_tags")
            XCTAssertEqual(json["tags"] as? [String], ["reviewed"])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let rows = try await client.bulkUpdateTransactions(budgetID: "b1", update: .init(transactionIDs: ["t1", "t2"], action: "add_tags", tags: ["reviewed"]), token: "secret")
        XCTAssertTrue(rows.isEmpty)
    }

    func testSingleQuickClearIssuesExactlyOneCanonicalMutation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/bulk")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["transaction_ids"] as? [String], ["t1"])
            XCTAssertEqual(json["action"] as? String, "set_cleared")
            XCTAssertEqual(json["cleared"] as? Bool, true)
            XCTAssertNil(json["tags"], "clearing-only requests must omit unrelated tags")
            XCTAssertNil(json["flag"], "clearing-only requests must omit unrelated flag")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        _ = try await client.bulkUpdateTransactions(budgetID: "b1", update: .init(transactionIDs: ["t1"], action: "set_cleared", cleared: true), token: "secret")
        XCTAssertEqual(requestCount, 1)
    }

    func testBulkMetadataOperationsOmitUnchangedFields() throws {
        func json(_ update: APITransactionBulkUpdate) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        }
        let flag = try json(.init(transactionIDs: ["t1"], action: "set_flag", flag: "blue"))
        XCTAssertEqual(flag["flag"] as? String, "blue")
        XCTAssertNil(flag["cleared"])
        XCTAssertNil(flag["tags"])

        let addTags = try json(.init(transactionIDs: ["t1"], action: "add_tags", tags: ["reviewed"]))
        XCTAssertEqual(addTags["tags"] as? [String], ["reviewed"])
        XCTAssertNil(addTags["cleared"])
        XCTAssertNil(addTags["flag"])
    }

    func testPayeeAliasCreateAndDeleteUseProtectedResourcePaths() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees/p1/aliases")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["display_name"] as? String, "Corner Shop")
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"a1","display_name":"Corner Shop"}"#.utf8))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees/p1/aliases/a1")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let alias = try await client.createPayeeAlias(budgetID: "b1", payeeID: "p1", displayName: "Corner Shop", token: "secret")
        XCTAssertEqual(alias.displayName, "Corner Shop")
        try await client.deletePayeeAlias(budgetID: "b1", payeeID: "p1", aliasID: alias.id, token: "secret")
        XCTAssertEqual(requestCount, 2)
    }

    func testPayeeManagementUsesBudgetScopedContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            switch requestCount {
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "include_archived", value: "true")])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["display_name"] as? String, "Neighborhood Market")
                XCTAssertEqual(json["default_category_id"] as? String, "c1")
                let response = Data(#"{"id":"p1","household_id":"h1","display_name":"Neighborhood Market","is_archived":false,"merged_into_payee_id":null,"default_category_id":"c1","transaction_count":0,"net_amount_minor":0,"aliases":[]}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
            default:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees/p1/merge")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["destination_payee_id"] as? String, "p2")
                let response = Data(#"{"id":"p2","household_id":"h1","display_name":"Grocer","is_archived":false,"merged_into_payee_id":null,"default_category_id":null,"transaction_count":1,"net_amount_minor":-12345,"aliases":[]}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
            }
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        _ = try await client.payees(budgetID: "b1", includeArchived: true, token: "secret")
        let created = try await client.createPayee(
            budgetID: "b1",
            payee: .init(displayName: "Neighborhood Market", defaultCategoryID: "c1"),
            token: "secret"
        )
        XCTAssertEqual(created.defaultCategoryID, "c1")
        let merged = try await client.mergePayee(budgetID: "b1", payeeID: "p1", destinationPayeeID: "p2", token: "secret")
        XCTAssertEqual(merged.id, "p2")
        XCTAssertEqual(requestCount, 3)
    }

    func testPayeeSearchUsesBoundedServerAuthoritativePage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "metadata")
            XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "20")
            XCTAssertEqual(items.first(where: { $0.name == "cursor" })?.value, "next")
            let response = Data(#"{"items":[{"id":"p1","household_id":"h1","display_name":"Metadata test","is_archived":false,"merged_into_payee_id":null,"default_category_id":"c1","transaction_count":1,"net_amount_minor":-200,"aliases":[]}],"next_cursor":null}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let page = try await client.searchPayees(budgetID: "b1", query: "metadata", limit: 20, cursor: "next", token: "secret")
        XCTAssertEqual(page.items.map(\.displayName), ["Metadata test"])
        XCTAssertNil(page.nextCursor)
    }

    func testCreateTransactionEncodesBalancedSplits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
            )
            XCTAssertNil(json["category_id"] as? String)
            let splits = try XCTUnwrap(json["splits"] as? [[String: Any]])
            XCTAssertEqual(splits.compactMap { $0["amount_minor"] as? Int }.reduce(0, +), -12500)
            let response = Data(#"{"id":"t1","budget_id":"b1","account_id":"a1","category_id":null,"amount_minor":-12500,"occurred_on":"2026-09-04","payee_name":"Store","memo":"","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"splits":[{"id":"s1","category_id":"c1","amount_minor":-10000,"memo":""},{"id":"s2","category_id":"c2","amount_minor":-2500,"memo":""}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        _ = try await client.createTransaction(
            budgetID: "b1",
            transaction: APITransactionCreate(
                accountID: "a1",
                categoryID: nil,
                amountMinor: -12500,
                occurredOn: "2026-09-04",
                payeeName: "Store",
                splits: [
                    APITransactionSplitCreate(categoryID: "c1", amountMinor: -10000),
                    APITransactionSplitCreate(categoryID: "c2", amountMinor: -2500),
                ]
            ),
            token: "secret"
        )
    }

    func testRefreshRotatesTokensAndLogoutAcceptsEmptyResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: String]
            )
            XCTAssertEqual(json["refresh_token"], requestCount == 1 ? "old-refresh" : "new-refresh")
            if requestCount == 1 {
                XCTAssertEqual(request.url?.path, "/api/v1/auth/refresh")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"bearer"}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/api/v1/auth/logout")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let tokens = try await client.refresh("old-refresh")
        XCTAssertEqual(tokens, APIAuthTokens(accessToken: "new-access", refreshToken: "new-refresh"))
        try await client.logout(tokens.refreshToken)
        XCTAssertEqual(requestCount, 2)
    }

    func testAllocationTransferCarriesOptimisticVersion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/allocation-transfers")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(json["amount_minor"] as? Int, 2500)
            XCTAssertEqual(json["expected_allocation_version"] as? Int, 7)
            let response = Data(#"{"id":"op1","budget_id":"b1","occurred_on":"2026-09-04","kind":"category_transfer","actor_user_id":"u1","note":"Priorities changed","source":"manual","allocation_version":8,"postings":[{"bucket":"category","category_id":"c1","amount_minor":-2500},{"bucket":"category","category_id":"c2","amount_minor":2500}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let operation = try await client.transferAllocation(
            budgetID: "b1",
            transfer: APIAllocationTransferCreate(
                sourceCategoryID: "c1",
                destinationCategoryID: "c2",
                amountMinor: 2500,
                occurredOn: "2026-09-04",
                note: "Priorities changed",
                expectedAllocationVersion: 7
            ),
            token: "secret"
        )

        XCTAssertEqual(operation.allocationVersion, 8)
        XCTAssertEqual(operation.postings.reduce(0) { $0 + $1.amountMinor }, 0)
    }

    func testFundingRequestUsesDelegatedCategoryAndExactMinorUnits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/requests")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(json["destination_category_id"] as? String, "child-entertainment")
            XCTAssertEqual(json["requested_amount_minor"] as? Int, 3500)
            let response = Data(#"{"id":"r1","requester_user_id":"child","request_type":"additional_allocation","destination_category_id":"child-entertainment","requested_amount_minor":3500,"reason":"New game","status":"pending","version":0,"approved_amount_minor":null,"source_category_id":null,"allocation_operation_id":null,"actions":[{"id":"a1","actor_user_id":"child","action":"submitted","amount_minor":3500,"note":"New game","created_at":"2026-09-04T12:00:00Z"}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let request = try await client.createFinancialRequest(
            budgetID: "b1",
            request: APIFinancialRequestCreate(
                destinationCategoryID: "child-entertainment",
                requestedAmountMinor: 3500,
                reason: "New game"
            ),
            token: "secret"
        )

        XCTAssertEqual(request.status, "pending")
        XCTAssertEqual(request.requestedAmountMinor, 3500)
        XCTAssertEqual(request.actions.map(\.action), ["submitted"])
    }

    func testSpendingReportUsesExplicitInclusiveDateRangeAndKeepsDrillDownIDs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/spending")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(Set(components?.queryItems ?? []), Set([
                URLQueryItem(name: "start_date", value: "2026-08-06"),
                URLQueryItem(name: "end_date", value: "2026-09-04"),
                URLQueryItem(name: "reconciled", value: "true"),
                URLQueryItem(name: "flag", value: "orange"),
                URLQueryItem(name: "tag", value: "essential")
            ]))
            let response = Data(#"{"start_date":"2026-08-06","end_date":"2026-09-04","currency_code":"USD","total_spending_minor":3182,"categories":[{"category_id":"dining","category_name":"Dining Out","category_group":"Food","spending_minor":3182,"transaction_ids":["t1"]}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.spendingReport(budgetID: "b1", startDate: "2026-08-06", endDate: "2026-09-04", reconciled: true, flags: ["orange"], tags: ["essential"], token: "secret")
        XCTAssertEqual(report.totalSpendingMinor, 3182)
        XCTAssertEqual(report.categories.first?.transactionIDs, ["t1"])
    }

    func testSpendingTrendsUseServerDimensionFiltersAndExactSeries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/spending-trends")
            let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "dimension", value: "payee")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "account_id", value: "a1")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "tag", value: "essential")))
            let response = Data(#"{"start_date":"2026-08-01","end_date":"2026-09-30","currency_code":"USD","dimension":"payee","total_spending_minor":9001,"series":[{"dimension_id":"payee:market","dimension_name":"Market","category_group":null,"spending_minor":9001,"transaction_ids":["purchase","refund"],"transaction_ids_truncated":true,"points":[{"period_start":"2026-08-01","period_end":"2026-08-31","spending_minor":10000,"transaction_ids":["purchase"]},{"period_start":"2026-09-01","period_end":"2026-09-30","spending_minor":-999,"transaction_ids":["refund"]}]}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.spendingTrendsReport(budgetID: "b1", startDate: "2026-08-01", endDate: "2026-09-30", dimension: "payee", accountIDs: ["a1"], tags: ["essential"], token: "secret")
        XCTAssertEqual(report.totalSpendingMinor, 9_001)
        XCTAssertEqual(report.series.first?.points.map(\.spendingMinor), [10_000, -999])
        XCTAssertEqual(report.series.first?.transactionIDs, ["purchase", "refund"])
        XCTAssertEqual(report.series.first?.transactionIDsTruncated, true)
    }

    func testIncomeSpendingReportDecodesExactMonthlyTrendAndDrillDownIDs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/income-spending")
            let response = Data(#"{"start_date":"2026-08-15","end_date":"2026-09-30","currency_code":"USD","income_minor":200000,"spending_minor":11500,"difference_minor":188500,"savings_rate":0.9425,"income_transaction_ids":["income"],"spending_transaction_ids":["split","refund","purchase"],"spending_transaction_ids_truncated":true,"periods":[{"period_start":"2026-08-15","period_end":"2026-08-31","income_minor":200000,"spending_minor":10000,"difference_minor":190000,"income_transaction_ids":["income"],"spending_transaction_ids":["split"]},{"period_start":"2026-09-01","period_end":"2026-09-30","income_minor":0,"spending_minor":1500,"difference_minor":-1500,"income_transaction_ids":[],"spending_transaction_ids":["refund","purchase"],"spending_transaction_ids_truncated":true}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.incomeSpendingReport(budgetID: "b1", startDate: "2026-08-15", endDate: "2026-09-30", token: "secret")
        XCTAssertEqual(report.periods.map(\.spendingMinor), [10_000, 1_500])
        XCTAssertEqual(report.periods[1].spendingTransactionIDs, ["refund", "purchase"])
        XCTAssertEqual(report.differenceMinor, 188_500)
        XCTAssertEqual(report.spendingTransactionIDsTruncated, true)
        XCTAssertEqual(report.periods[1].spendingTransactionIDsTruncated, true)
    }

    func testNetWorthReportUsesExplicitTrackingAndAccountScope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/net-worth")
            let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "include_tracking", value: "true")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "account_id", value: "a1")))
            let response = Data(#"{"start_date":"2026-07-01","end_date":"2026-08-31","currency_code":"USD","assets_minor":125000,"liabilities_minor":-50000,"net_worth_minor":75000,"points":[{"as_of":"2026-07-31","assets_minor":125000,"liabilities_minor":-50000,"net_worth_minor":75000,"transaction_ids":["opening"]}],"accounts":[{"account_id":"a1","account_name":"Checking","account_type":"checking","is_on_budget":true,"balance_minor":75000,"transaction_ids":["opening"]}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.netWorthReport(budgetID: "b1", startDate: "2026-07-01", endDate: "2026-08-31", accountIDs: ["a1"], token: "secret")
        XCTAssertEqual(report.netWorthMinor, 75_000)
        XCTAssertEqual(report.points.first?.transactionIDs, ["opening"])
        XCTAssertEqual(report.accounts.first?.accountID, "a1")
    }

    func testDebtReportUsesExactMinorUnitsAndAccountScope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/debt")
            let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(Set(query), Set([
                URLQueryItem(name: "start_date", value: "2026-01-01"),
                URLQueryItem(name: "end_date", value: "2026-09-30"),
                URLQueryItem(name: "account_id", value: "card")
            ]))
            let response = Data(#"{"start_date":"2026-01-01","end_date":"2026-09-30","currency_code":"USD","opening_debt_minor":125000,"debt_minor":90001,"principal_reduction_minor":34999,"points":[{"as_of":"2026-01-31","debt_minor":125000},{"as_of":"2026-09-30","debt_minor":90001}],"accounts":[{"account_id":"card","account_name":"Credit Card","account_type":"credit","is_on_budget":true,"debt_minor":90001}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.debtReport(budgetID: "b1", startDate: "2026-01-01", endDate: "2026-09-30", accountIDs: ["card"], token: "secret")
        XCTAssertEqual(report.openingDebtMinor, 125_000)
        XCTAssertEqual(report.debtMinor, 90_001)
        XCTAssertEqual(report.principalReductionMinor, 34_999)
        XCTAssertEqual(report.points.map(\.debtMinor), [125_000, 90_001])
        XCTAssertEqual(report.accounts.first?.accountID, "card")
    }

    func testPlanPerformanceReportDecodesExactHistoricalObservations() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/plan-performance")
            let response = Data(#"{"start_date":"2026-07-01","end_date":"2026-08-31","currency_code":"USD","points":[{"period_start":"2026-07-01","period_end":"2026-07-31","assigned_minor":40000,"activity_minor":-12000,"spending_minor":12000,"carried_available_minor":0,"available_minor":28000,"overspent_minor":0,"ready_to_assign_minor":60000}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.planPerformanceReport(budgetID: "b1", startDate: "2026-07-01", endDate: "2026-08-31", token: "secret")
        XCTAssertEqual(report.points.first?.assignedMinor, 40_000)
        XCTAssertEqual(report.points.first?.spendingMinor, 12_000)
        XCTAssertEqual(report.points.first?.readyToAssignMinor, 60_000)
    }

    func testResilienceReportKeepsUnavailableMetricsExplicit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/resilience")
            XCTAssertTrue(request.url?.query?.contains("horizon_days=30") == true)
            let response = Data(#"{"as_of":"2026-09-01","through":"2026-10-01","currency_code":"USD","cash_buffer_minor":100000,"current_on_budget_minor":90000,"projected_on_budget_minor":110000,"lowest_projected_on_budget_minor":85000,"scheduled_income_minor":50000,"scheduled_outflows_minor":30000,"expected_margin_minor":20000,"essential_expense_coverage_days":null,"emergency_fund_coverage_days":null,"unavailable_metrics":{"essential_expense_coverage_days":"Classification unavailable."}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.resilienceReport(budgetID: "b1", token: "secret")
        XCTAssertEqual(report.cashBufferMinor, 100_000)
        XCTAssertEqual(report.expectedMarginMinor, 20_000)
        XCTAssertNil(report.essentialExpenseCoverageDays)
        XCTAssertEqual(report.unavailableMetrics["essential_expense_coverage_days"], "Classification unavailable.")
    }

    func testReportExportDownloadsOpenCSVWithBearerCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/export.csv")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertTrue(request.url?.query?.contains("start_date=2026-09-01") == true)
            let response = Data("report,amount_minor\nspending,2500\n".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/csv"])!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let data = try await client.reportExportCSV(budgetID: "b1", startDate: "2026-09-01", endDate: "2026-09-30", token: "secret")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "report,amount_minor\nspending,2500\n")
    }

    func testStructuredConflictDetailSurfacesActionableMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            // Allocation version conflicts return `detail` as an object, not a string.
            let body = Data(#"{"detail":{"message":"The allocation plan changed. Refresh and try again.","current_allocation_version":9}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        do {
            _ = try await client.transferAllocation(
                budgetID: "b1",
                transfer: APIAllocationTransferCreate(
                    sourceCategoryID: "c1", destinationCategoryID: "c2", amountMinor: 2500,
                    occurredOn: "2026-09-04", note: "", expectedAllocationVersion: 7
                ),
                token: "secret"
            )
            XCTFail("Expected a server conflict error")
        } catch let APIClientError.server(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "The allocation plan changed. Refresh and try again.")
        }
    }

    func testStringConflictDetailStillSurfacesMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let body = Data(#"{"detail":"Source category has insufficient funds"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        do {
            _ = try await client.transferAllocation(
                budgetID: "b1",
                transfer: APIAllocationTransferCreate(
                    sourceCategoryID: "c1", destinationCategoryID: "c2", amountMinor: 2500,
                    occurredOn: "2026-09-04", note: "", expectedAllocationVersion: 7
                ),
                token: "secret"
            )
            XCTFail("Expected a server conflict error")
        } catch let APIClientError.server(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "Source category has insufficient funds")
        }
    }

    func testUpdateAndDeleteTransactionUseResourcePath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1")
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            let response = Data(#"{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"groceries","amount_minor":-12000,"occurred_on":"2026-09-04","payee_name":"Market","memo":"Corrected","is_cleared":true,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"splits":[]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let body = APITransactionCreate(accountID: "a1", categoryID: "groceries", amountMinor: -12000, occurredOn: "2026-09-04", payeeName: "Market", memo: "Corrected", isCleared: true)
        let updated = try await client.updateTransaction(budgetID: "b1", transactionID: "t1", transaction: body, token: "secret")
        XCTAssertEqual(updated.categoryID, "groceries")
        try await client.deleteTransaction(budgetID: "b1", transactionID: "t1", token: "secret")
        XCTAssertEqual(methods, ["PUT", "DELETE"])
    }

    func testUpdateAndDeleteTransferUseLogicalTransferPath() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration); var methods: [String] = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transfers/xfer1"); methods.append(request.httpMethod ?? "")
            if request.httpMethod == "DELETE" { return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data()) }
            let response = Data(#"{"transfer_id":"xfer1","source":{"id":"out","budget_id":"b1","account_id":"a1","category_id":null,"amount_minor":-2000,"occurred_on":"2026-09-04","payee_name":"Transfer","memo":"fixed","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":"xfer1","splits":[]},"destination":{"id":"in","budget_id":"b1","account_id":"a2","category_id":null,"amount_minor":2000,"occurred_on":"2026-09-04","payee_name":"Transfer","memo":"fixed","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":"xfer1","splits":[]}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let body = APITransferCreate(sourceAccountID: "a1", destinationAccountID: "a2", amountMinor: 2_000, occurredOn: "2026-09-04", memo: "fixed")
        let updated = try await client.updateTransfer(budgetID: "b1", transferID: "xfer1", transfer: body, token: "secret")
        XCTAssertEqual(updated.transferID, "xfer1")
        try await client.deleteTransfer(budgetID: "b1", transferID: "xfer1", token: "secret")
        XCTAssertEqual(methods, ["PUT", "DELETE"])
    }

    func testScheduledTransactionCreateListAndRealizeUseContractPaths() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var seen: [(String, String)] = []
        MockURLProtocol.handler = { request in
            seen.append((request.httpMethod ?? "", request.url?.path ?? ""))
            let path = request.url?.path ?? ""
            if path.hasSuffix("/realize") {
                let body = Data(#"{"scheduled_transaction_id":"s1","transaction_ids":["t9"],"realized_on":"2026-09-01","next_date":"2026-10-01","is_active":true,"last_realized_on":"2026-09-01"}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            if request.httpMethod == "POST" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["amount_minor"] as? Int, -1599)
                XCTAssertEqual(json["recurrence_unit"] as? String, "months")
                XCTAssertEqual(json["payee_id"] as? String, "p1")
            }
            let body = Data(#"{"id":"s1","budget_id":"b1","account_id":"a1","destination_account_id":null,"category_id":"c1","payee_id":"p1","name":"Netflix","amount_minor":-1599,"next_date":"2026-10-01","recurrence_unit":"months","interval_count":1,"memo":"","is_active":true,"last_realized_on":null}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 201 : 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let created = try await client.createScheduledTransaction(budgetID: "b1", schedule: APIScheduledTransactionCreate(accountID: "a1", categoryID: "c1", payeeID: "p1", name: "Netflix", amountMinor: -1599, nextDate: "2026-10-01", recurrenceUnit: "months"), token: "secret")
        XCTAssertEqual(created.id, "s1")
        XCTAssertEqual(created.payeeID, "p1")
        XCTAssertEqual(created.recurrenceUnit, "months")

        let realized = try await client.realizeScheduledTransaction(budgetID: "b1", scheduleID: "s1", token: "secret")
        XCTAssertEqual(realized.transactionIDs, ["t9"])
        XCTAssertEqual(realized.nextDate, "2026-10-01")

        try await client.deleteScheduledTransaction(budgetID: "b1", scheduleID: "s1", token: "secret")

        XCTAssertEqual(seen.map(\.0), ["POST", "POST", "DELETE"])
        XCTAssertEqual(seen[0].1, "/api/v1/budgets/b1/scheduled-transactions")
        XCTAssertEqual(seen[1].1, "/api/v1/budgets/b1/scheduled-transactions/s1/realize")
        XCTAssertEqual(seen[2].1, "/api/v1/budgets/b1/scheduled-transactions/s1")
    }

    func testScheduledManagementListRequestsInactiveRecords() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/v1/budgets/b1/scheduled-transactions")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "include_inactive", value: "true")])
            let body = Data(#"[{"id":"paused","budget_id":"b1","account_id":"a1","destination_account_id":null,"category_id":"c1","name":"Paused","amount_minor":-1599,"next_date":"2026-10-01","recurrence_unit":"months","interval_count":1,"memo":"","is_active":false,"last_realized_on":null}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let schedules = try await client.scheduledTransactions(budgetID: "b1", includeInactive: true, token: "secret")
        XCTAssertEqual(schedules.map(\.isActive), [false])
    }

    func testBootstrapRequestEncodesExactBackendFieldNames() throws {
        // The backend BootstrapRequest requires snake_case display_name / household_name. Lock the
        // wire encoding so a fresh iOS first-time setup cannot silently drift from the contract.
        let data = try JSONEncoder().encode(BootstrapRequest(
            email: "owner@example.com",
            password: "correct horse battery staple",
            displayName: "Owner",
            householdName: "Home"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["email", "password", "display_name", "household_name"])
        XCTAssertEqual(json["display_name"] as? String, "Owner")
        XCTAssertEqual(json["household_name"] as? String, "Home")
        XCTAssertEqual(json["email"] as? String, "owner@example.com")
    }

    func testValidationErrorArraySurfacesReadableFieldMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/bootstrap")
            // FastAPI 422: `detail` is an array of {loc, msg, type}, not a string or {message}.
            let body = Data(#"{"detail":[{"type":"string_too_short","loc":["body","password"],"msg":"String should have at least 12 characters","input":"short"}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        do {
            _ = try await client.bootstrap(BootstrapRequest(email: "owner@example.com", password: "short", displayName: "Owner", householdName: "Home"))
            XCTFail("Expected a validation error")
        } catch let APIClientError.server(status, message) {
            XCTAssertEqual(status, 422)
            // Humanized field label + FastAPI message, without raw type/loc internals.
            XCTAssertEqual(message, "Password: String should have at least 12 characters")
        }
    }

    func testMissingOptionalPlanningResourcesDecodeSuccessfulNull() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertTrue(["/api/v1/budgets/b1/delegated-budgets/me", "/api/v1/budgets/b1/categories/c1/target"].contains(request.url?.path ?? ""))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("null".utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let delegated = try await client.delegatedBudget(budgetID: "b1", token: "secret")
        let target = try await client.categoryTarget(budgetID: "b1", categoryID: "c1", token: "secret")
        XCTAssertNil(delegated)
        XCTAssertNil(target)
    }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
