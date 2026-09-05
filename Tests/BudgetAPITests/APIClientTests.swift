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
                URLQueryItem(name: "end_date", value: "2026-09-04")
            ]))
            let response = Data(#"{"start_date":"2026-08-06","end_date":"2026-09-04","currency_code":"USD","total_spending_minor":3182,"categories":[{"category_id":"dining","category_name":"Dining Out","category_group":"Food","spending_minor":3182,"transaction_ids":["t1"]}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.spendingReport(budgetID: "b1", startDate: "2026-08-06", endDate: "2026-09-04", token: "secret")
        XCTAssertEqual(report.totalSpendingMinor, 3182)
        XCTAssertEqual(report.categories.first?.transactionIDs, ["t1"])
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
