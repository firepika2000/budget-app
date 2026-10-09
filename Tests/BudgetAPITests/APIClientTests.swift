import XCTest
@testable import BudgetAPI

final class APIClientTests: XCTestCase {
    func testDevicePairingAndSessionManagementUseCanonicalContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var requests: [String] = []
        MockURLProtocol.handler = { request in
            requests.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" && request.url!.path.hasSuffix("pairing-code") ? 201 : 200, httpVersion: nil, headerFields: nil)!
            switch request.url!.path {
            case "/api/v1/auth/login":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertEqual(body["device_name"] as? String, "Rey's iPhone")
                return (response, Data(#"{"access_token":"A","refresh_token":"R"}"#.utf8))
            case "/api/v1/auth/pairing-code":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
                return (response, Data(#"{"code":"secret","server_url":"https://budget.example.com","expires_at":"2026-10-01T12:05:00Z"}"#.utf8))
            case "/api/v1/auth/pair":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertEqual(body as NSDictionary, ["code": "secret", "device_name": "Second iPhone"] as NSDictionary)
                return (response, Data(#"{"access_token":"B","refresh_token":"R2"}"#.utf8))
            case "/api/v1/auth/sessions":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
                return (response, Data(#"[{"id":"s1","device_name":"Second iPhone","created_at":"2026-10-01T12:00:00Z","expires_at":"2026-10-31T12:00:00Z"}]"#.utf8))
            case "/api/v1/auth/sessions/s1":
                XCTAssertEqual(request.httpMethod, "DELETE")
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default: XCTFail("Unexpected request"); return (response, Data())
            }
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        _ = try await client.login(email: "owner@example.com", password: "password", deviceName: "Rey's iPhone")
        let pairing = try await client.createPairingCode(token: "current")
        XCTAssertEqual(pairing.serverURL, "https://budget.example.com")
        _ = try await client.redeemPairingCode(pairing.code, deviceName: "Second iPhone")
        let sessions = try await client.deviceSessions(token: "current")
        XCTAssertEqual(sessions.first?.deviceName, "Second iPhone")
        try await client.revokeDeviceSession("s1", token: "current")
        XCTAssertEqual(requests, ["POST /api/v1/auth/login", "POST /api/v1/auth/pairing-code", "POST /api/v1/auth/pair", "GET /api/v1/auth/sessions", "DELETE /api/v1/auth/sessions/s1"])
    }
    func testBudgetCreationPolicyIsExplicitAndLegacyOmissionIsPreserved() throws {
        let encoder = JSONEncoder()
        let legacy = try JSONSerialization.jsonObject(with: encoder.encode(APIBudgetCreate(householdID: "h1", name: "Legacy", currencyCode: "USD"))) as! [String: Any]
        XCTAssertNil(legacy["cash_rollover_policy"])
        XCTAssertEqual(Set(legacy.keys), ["household_id", "name", "currency_code"])
        for policy in APICashRolloverPolicy.allCases {
            let value = APIBudgetCreate(householdID: "h1", name: "Explicit", currencyCode: "USD", cashRolloverPolicy: policy)
            let payload = try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
            XCTAssertEqual(payload["cash_rollover_policy"] as? String, policy.rawValue)
            XCTAssertEqual(Set(payload.keys), ["household_id", "name", "currency_code", "cash_rollover_policy"])
        }
    }

    func testBudgetDeletionSendsExactTypedConfirmation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            XCTAssertEqual(body as NSDictionary, ["confirmation_name": "My Budget"] as NSDictionary)
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try APIClient(
            baseURL: URL(string: "https://budget.example.com")!,
            session: URLSession(configuration: configuration)
        )
        try await client.deleteBudget(budgetID: "b1", confirmationName: "My Budget", token: "current")
    }

    func testCashRolloverPolicyContractUsesExactVersionedSelectionAndBoundedHistory() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.hasSuffix("/history") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) }), ["limit": "50", "before_version": "3"])
                return (response, Data(#"{"items":[{"id":"p1","effective_month":"2026-10-01","policy":"absorb_next_month","version":1,"source":"user_selection","actor_user_id":"owner","created_at":"2026-09-18T12:00:00Z"}],"next_before_version":1}"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/api/v1/budgets/b1/cash-rollover-policy")
            if request.httpMethod == "PUT" {
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertEqual(Set(body.keys), ["policy", "effective_month", "expected_policy_version", "expected_allocation_version"])
                XCTAssertEqual(body["policy"] as? String, "absorb_next_month")
                XCTAssertEqual(body["effective_month"] as? String, "2026-10-01")
                XCTAssertEqual(body["expected_policy_version"] as? Int, 0)
                XCTAssertEqual(body["expected_allocation_version"] as? Int, 7)
            }
            return (response, Data(#"{"current_month":"2026-09-01","current_policy":"carry_category_deficit","policy_version":1,"allocation_version":8,"pending":[{"effective_month":"2026-10-01","policy":"absorb_next_month","version":1}]}"#.utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let current = try await client.cashRolloverPolicy(budgetID: "b1", token: "current")
        XCTAssertEqual(current.currentPolicy, .carryCategoryDeficit)
        let updated = try await client.selectCashRolloverPolicy(budgetID: "b1", selection: .init(policy: .absorbNextMonth, effectiveMonth: "2026-10-01", expectedPolicyVersion: 0, expectedAllocationVersion: 7), token: "current")
        XCTAssertEqual(updated.pending.first?.policy, .absorbNextMonth)
        let history = try await client.cashRolloverPolicyHistory(budgetID: "b1", beforeVersion: 3, token: "current")
        XCTAssertEqual(history.items.first?.actorUserID, "owner")
        XCTAssertEqual(history.nextBeforeVersion, 1)
        XCTAssertEqual(methods, ["GET", "PUT", "GET"])
    }

    func testTargetSnoozeUsesMonthScopedMetadataOnlyRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/categories/c1/target/snooze/2027-02-01")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Bool]
            XCTAssertEqual(body, ["is_snoozed": true])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"category_id":"c1","month":"2027-02-01","is_snoozed":true}"#.utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        try await client.setCategoryTargetSnoozed(budgetID: "b1", categoryID: "c1", month: "2027-02-01", isSnoozed: true, token: "current")
    }

    func testTargetHistoryUsesBoundedAttributedContractAndExactMoney() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/categories/c1/target/history")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(items.first(where: { $0.name == "offset" })?.value, "50")
            let body = Data(#"[{"id":"r1","category_id":"c1","target_id":"tg1","action":"updated","actor_user_id":"u1","actor_display_name":"Alex","before_snapshot":{"target_type":"monthly_funding","target_amount_minor":9007199254740991,"target_date":null,"recurrence_months":null,"minimum_contribution_minor":0,"priority":50,"is_active":true},"after_snapshot":{"target_type":"target_by_date","target_amount_minor":9007199254740992,"target_date":"2027-06-01","recurrence_months":null,"minimum_contribution_minor":5000,"priority":80,"is_active":true},"affected_month":null,"created_at":"2026-10-08T17:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let rows = try await client.categoryTargetHistory(budgetID: "b1", categoryID: "c1", limit: 25, offset: 50, token: "rotated")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].actorDisplayName, "Alex")
        XCTAssertEqual(rows[0].beforeSnapshot?.targetAmountMinor, 9_007_199_254_740_991)
        XCTAssertEqual(rows[0].afterSnapshot?.targetAmountMinor, 9_007_199_254_740_992)
    }

    func testDebtCostUsesAuthorizedAccountFilterAndPreservesUnknownAndExactMoney() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/debt-cost")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a1")
            let body = Data(#"{"as_of":"2026-09-18","currency_code":"USD","model":"unchanged_balance_monthly_apr","accounts":[{"account_id":"a1","account_name":"Debt","principal_minor":9007199254740993,"effective_rate_basis_points":null,"estimated_monthly_interest_minor":null,"missing_fields":["annual_rate_basis_points"]}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let value = try await client.debtCost(budgetID: "b1", accountIDs: ["a1"], token: "current")
        XCTAssertEqual(value.accounts.first?.principalMinor, 9_007_199_254_740_993)
        XCTAssertNil(value.accounts.first?.estimatedMonthlyInterestMinor)
    }
    override func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    func testInsightsSummaryPreservesExactMoneyAndAuthorizedQueryContext() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reports/summary")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            for (name, value) in [("start_date", "2026-09-01"), ("end_date", "2026-09-30"), ("account_id", "a1"), ("member_id", "u1"), ("payee", "Cafe"), ("cleared", "true"), ("reconciled", "false"), ("flag", "orange"), ("tag", "qa"), ("include_tracking", "true")] {
                XCTAssertTrue(query.contains(URLQueryItem(name: name, value: value)))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"currency_code":"USD","net_cash_flow_minor":9007199254740993,"net_worth_minor":null,"debt_minor":null,"recorded_interest_month_minor":null,"expected_margin_minor":null}"#.utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: transport)
        let result = try await client.insightsSummary(budgetID: "b1", startDate: "2026-09-01", endDate: "2026-09-30", accountIDs: ["a1"], memberIDs: ["u1"], payees: ["Cafe"], cleared: true, reconciled: false, flags: ["orange"], tags: ["qa"], includeTracking: true, token: "rotated-token")
        XCTAssertEqual(result.netCashFlowMinor, 9_007_199_254_740_993)
        XCTAssertNil(result.netWorthMinor)
        XCTAssertNil(result.debtMinor)
    }

    func testRejectsInsecureRemoteServer() {
        XCTAssertThrowsError(try APIClient(baseURL: URL(string: "http://example.com")!)) { error in
            XCTAssertEqual(error as? APIClientError, .insecureRemoteServer)
        }
    }

    func testAllowsLocalHTTPForSimulatorDevelopment() {
        XCTAssertNoThrow(try APIClient(baseURL: URL(string: "http://localhost:8080")!))
    }

    func testHouseholdLifecycleUsesOwnerScopedAuthenticatedRoutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requests: [String] = []
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            let path = components.path
            let recordedTarget = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
            requests.append("\(request.httpMethod ?? "") \(recordedTarget)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            if request.url?.absoluteString.contains("/access-events") == true {
                let query = components.queryItems ?? []
                XCTAssertTrue(query.contains(.init(name: "limit", value: "25")))
                XCTAssertTrue(query.contains(.init(name: "offset", value: "50")))
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"[{"id":"e1","event_type":"member_removed","actor_display_name":"Owner","subject_display_name":"Sam","detail":null,"created_at":"2026-09-16T12:00:00Z"}]"#.utf8))
            }
            if request.httpMethod == "POST" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"invitation_token":"private-code","email":"sam@example.com","role":"adult","expires_at":"2026-09-23T12:00:00Z"}"#.utf8))
            }
            if request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        _ = try await client.householdInvitations(householdID: "h1", token: "current-token")
        let secret = try await client.createHouseholdInvitation(householdID: "h1", value: .init(email: "sam@example.com", role: "adult"), token: "current-token")
        XCTAssertEqual(secret.invitationToken, "private-code")
        try await client.cancelHouseholdInvitation(householdID: "h1", invitationID: "i1", token: "current-token")
        try await client.removeHouseholdMember(householdID: "h1", userID: "u2", token: "current-token")
        let events = try await client.householdAccessEvents(householdID: "h1", limit: 25, offset: 50, token: "current-token")
        XCTAssertEqual(events.first?.eventType, "member_removed")
        XCTAssertEqual(requests, [
            "GET /api/v1/households/h1/invitations",
            "POST /api/v1/households/h1/invitations",
            "DELETE /api/v1/households/h1/invitations/i1",
            "DELETE /api/v1/households/h1/members/u2",
            "GET /api/v1/households/h1/access-events?limit=25&offset=50",
        ])
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

    func testAccountStatusUpdateUsesMetadataPathWithoutFinancialFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let body = try requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json as NSDictionary, ["name": "Checking", "account_type": "checking", "is_closed": true] as NSDictionary)
            let response = Data(#"{"id":"a1","budget_id":"b1","name":"Checking","account_type":"checking","is_on_budget":true,"is_closed":true,"reconciled_balance_minor":null,"payment_category_id":null}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let account = try await client.updateAccount(budgetID: "b1", accountID: "a1", account: .init(name: "Checking", accountType: "checking", isClosed: true), token: "secret")
        XCTAssertTrue(account.isClosed)
    }

    func testAccountHistoryUsesBoundedAccountScopedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/history")
            XCTAssertEqual(request.url?.query, "limit=25&offset=50")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            let response = Data(#"[{"id":"r1","account_id":"a1","action":"updated","actor_user_id":"u1","actor_display_name":"Owner","before_snapshot":{"name":"Checking","account_type":"checking","is_on_budget":true,"is_closed":false,"payment_category_id":null},"after_snapshot":{"name":"Daily Checking","account_type":"checking","is_on_budget":true,"is_closed":false,"payment_category_id":null},"created_at":"2026-10-08T12:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let history = try await client.accountHistory(
            budgetID: "b1", accountID: "a1", limit: 25, offset: 50, token: "current-token"
        )
        XCTAssertEqual(history.first?.beforeSnapshot?.name, "Checking")
        XCTAssertEqual(history.first?.afterSnapshot.name, "Daily Checking")
        XCTAssertEqual(history.first?.actorDisplayName, "Owner")
    }

    func testBudgetStructureHistoryUsesBoundedResourceScopedContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestedPaths: [String] = []
        MockURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query, "limit=10&offset=20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            let response = Data(#"[{"id":"r1","resource_type":"category","resource_id":"c1","action":"updated","actor_user_id":"u1","actor_display_name":"Owner","before_snapshot":{"group_id":"g1","name":"Food","icon_name":null,"note":null,"sort_order":0,"is_archived":false,"is_essential":true,"is_emergency_fund":false,"delegated_user_id":null},"after_snapshot":{"group_id":"g1","name":"Groceries","icon_name":null,"note":null,"sort_order":0,"is_archived":false,"is_essential":true,"is_emergency_fund":false,"delegated_user_id":null},"created_at":"2026-10-08T12:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let category = try await client.categoryHistory(
            budgetID: "b1", categoryID: "c1", limit: 10, offset: 20, token: "current-token"
        )
        let group = try await client.categoryGroupHistory(
            budgetID: "b1", groupID: "g1", limit: 10, offset: 20, token: "current-token"
        )
        XCTAssertEqual(requestedPaths, [
            "/api/v1/budgets/b1/categories/c1/history",
            "/api/v1/budgets/b1/category-groups/g1/history",
        ])
        XCTAssertEqual(category.first?.beforeSnapshot?.name, "Food")
        XCTAssertEqual(category.first?.afterSnapshot.name, "Groceries")
        XCTAssertEqual(group.first?.actorDisplayName, "Owner")
    }

    func testDebtTermsUseExactTypedAccountScopedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/card1/debt-terms")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["terms_type"] as? String, "credit_card")
            XCTAssertEqual(json["annual_rate_basis_points"] as? Int, 1999)
            XCTAssertEqual(json["minimum_payment_minor"] as? Int, 3500)
            XCTAssertNil(json["scheduled_payment_minor"])
            let response = Data(#"{"account_id":"card1","budget_id":"b1","terms_type":"credit_card","annual_rate_basis_points":1999,"rate_type":"variable","payment_frequency":"monthly","scheduled_payment_minor":null,"minimum_payment_rule":"fixed","minimum_payment_minor":3500,"minimum_payment_rate_basis_points":null,"due_day":18,"statement_day":21,"original_principal_minor":null,"original_term_months":null,"remaining_term_months":null,"promotional_rate_basis_points":null,"promotional_ends_on":null,"projection_ready":true,"missing_projection_fields":[],"updated_at":"2026-09-16T12:00:00Z"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let result = try await client.updateAccountDebtTerms(
            budgetID: "b1", accountID: "card1",
            terms: .init(termsType: "credit_card", annualRateBasisPoints: 1999, rateType: "variable",
                         paymentFrequency: "monthly", minimumPaymentRule: "fixed",
                         minimumPaymentMinor: 3500, dueDay: 18, statementDay: 21),
            token: "secret"
        )
        XCTAssertTrue(result.projectionReady)
        XCTAssertEqual(result.minimumPaymentMinor, 3500)
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
            XCTAssertEqual(json["client_operation_id"] as? String, "b4a31971-273c-4692-a0ce-dcae1889c9a6")
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
                payeeName: "Market",
                clientOperationID: "b4a31971-273c-4692-a0ce-dcae1889c9a6"
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

    func testTransactionListDecodesCreatorAndLatestEditorProvenance() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions")
            let response = Data(#"[{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"c1","amount_minor":-200,"occurred_on":"2026-09-04","created_at":"2026-09-04T12:00:00Z","payee_name":"Market","memo":"Corrected","is_cleared":false,"is_reconciled":false,"created_by_user_id":"u1","created_by_display_name":"Alex","last_modified_by_user_id":"u2","last_modified_by_display_name":"Sam","last_modified_at":"2026-09-05T13:30:00Z","transfer_id":null,"splits":[]}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let transactions = try await client.transactions(budgetID: "b1", token: "secret")
        let transaction = try XCTUnwrap(transactions.first)
        XCTAssertEqual(transaction.createdByDisplayName, "Alex")
        XCTAssertEqual(transaction.lastModifiedByUserID, "u2")
        XCTAssertEqual(transaction.lastModifiedByDisplayName, "Sam")
        XCTAssertEqual(transaction.lastModifiedAt, "2026-09-05T13:30:00Z")
    }

    func testTransactionHistoryUsesBoundedAuthorizedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transactions/t1/history")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(.init(name: "limit", value: "25")))
            XCTAssertTrue(items.contains(.init(name: "offset", value: "50")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"[{"id":"h1","action":"updated","actor_user_id":"u2","actor_display_name":"Sam","changed_fields":["amount_minor","memo"],"changes":[{"field":"amount_minor","value_kind":"money_minor","before_value":"-1200","after_value":"-1350"}],"created_at":"2026-09-05T13:30:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let history = try await client.transactionHistory(budgetID: "b1", transactionID: "t1", limit: 25, offset: 50, token: "secret")
        XCTAssertEqual(history.first?.actorDisplayName, "Sam")
        XCTAssertEqual(history.first?.changedFields, ["amount_minor", "memo"])
        XCTAssertEqual(history.first?.changes?.first?.beforeValue, "-1200")
        XCTAssertEqual(history.first?.changes?.first?.afterValue, "-1350")
    }

    func testRecentTransactionChangesUsesBoundedBudgetContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/transaction-changes")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(.init(name: "limit", value: "5")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            let response = Data(#"[{"id":"h1","transaction_id":"t1","transaction_payee_name":"Market","transaction_occurred_on":"2026-09-04","action":"updated","actor_user_id":"u2","actor_display_name":"Sam","changed_fields":["memo"],"changes":[],"created_at":"2026-09-05T13:30:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let changes = try await client.recentTransactionChanges(budgetID: "b1", limit: 5, token: "current-token")
        XCTAssertEqual(changes.first?.transactionID, "t1")
        XCTAssertEqual(changes.first?.transactionPayeeName, "Market")
        XCTAssertEqual(changes.first?.transactionOccurredOn, "2026-09-04")
    }

    func testReconciliationHistoryUsesBoundedAccountContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/reconciliations")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(.init(name: "limit", value: "25")))
            XCTAssertTrue(items.contains(.init(name: "offset", value: "50")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"[{"id":"r1","account_id":"a1","actor_user_id":"u1","actor_display_name":"Rey","statement_date":"2026-09-30","statement_balance_minor":198800,"cleared_balance_before_minor":199000,"reconciled_transaction_count":4,"adjustment_transaction_id":"t9","created_at":"2026-10-01T12:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let history = try await client.reconciliationHistory(budgetID: "b1", accountID: "a1", limit: 25, offset: 50, token: "secret")
        XCTAssertEqual(history.first?.statementBalanceMinor, 198_800)
        XCTAssertEqual(history.first?.actorDisplayName, "Rey")
        XCTAssertEqual(history.first?.adjustmentTransactionID, "t9")
    }

    func testRecentReconciliationHistoryUsesOneBoundedBudgetRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/reconciliations")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items, [.init(name: "limit", value: "5")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"[{"id":"r2","account_id":"a2","actor_user_id":"u1","actor_display_name":"Rey","statement_date":"2026-10-01","statement_balance_minor":250000,"cleared_balance_before_minor":250000,"reconciled_transaction_count":2,"adjustment_transaction_id":null,"created_at":"2026-10-02T12:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let history = try await client.recentReconciliationHistory(budgetID: "b1", token: "secret")
        XCTAssertEqual(history.map(\.accountID), ["a2"])
    }

    func testAllocationHistoryUsesBoundedPageContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/allocations/page")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(.init(name: "limit", value: "50")))
            XCTAssertTrue(items.contains(.init(name: "cursor", value: "opaque-cursor")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"{"items":[{"id":"op1","budget_id":"b1","occurred_on":"2026-09-05","kind":"assignment","actor_user_id":"u1","actor_display_name":"Alex","note":"","source":"manual","allocation_version":7,"postings":[{"bucket":"ready_to_assign","category_id":null,"amount_minor":-500},{"bucket":"category","category_id":"c1","amount_minor":500}]}],"next_cursor":"next-page"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let page = try await client.allocationOperationsPage(budgetID: "b1", limit: 50, cursor: "opaque-cursor", token: "secret")
        XCTAssertEqual(page.items.first?.actorDisplayName, "Alex")
        XCTAssertEqual(page.nextCursor, "next-page")
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
            XCTAssertTrue(items.contains(.init(name: "payee_id", value: "p1")))
            XCTAssertTrue(items.contains(.init(name: "minimum_amount_minor", value: "-5000")))
            XCTAssertTrue(items.contains(.init(name: "cleared", value: "true")))
            XCTAssertTrue(items.contains(.init(name: "lifecycle_status", value: "voided")))
            XCTAssertTrue(items.contains(.init(name: "sort", value: "amount_asc")))
            XCTAssertTrue(items.contains(.init(name: "cursor", value: "opaque")))
            XCTAssertTrue(items.contains(.init(name: "limit", value: "50")))
            let response = Data(#"{"items":[{"id":"t1","budget_id":"b1","account_id":"a1","category_id":"c1","payee_id":"p1","amount_minor":-1200,"occurred_on":"2026-09-04","created_at":"2026-09-04T12:00:00Z","payee_name":"Market","memo":"","is_cleared":true,"is_reconciled":false,"created_by_user_id":"u1","transfer_id":null,"scheduled_transaction_id":null,"splits":[]}],"next_cursor":"next","total_count":2}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let page = try await client.searchTransactions(
            budgetID: "b1",
            query: .init(search: "market", accountIDs: ["a1"], categoryIDs: ["c1"], payeeIDs: ["p1"], minimumAmountMinor: -5000, lifecycleStatuses: ["voided"], cleared: true, sort: "amount_asc", limit: 50, cursor: "opaque"),
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

    func testPayeeHistoryUsesBoundedBudgetScopedContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/payees/p1/history")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(items.first(where: { $0.name == "offset" })?.value, "50")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"[{"id":"r1","payee_id":"p1","budget_id":"b1","action":"updated","actor_user_id":"u1","actor_display_name":"Owner","before_snapshot":{"display_name":"Market"},"after_snapshot":{"display_name":"Neighborhood Market"},"created_at":"2026-10-08T12:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let history = try await client.payeeHistory(
            budgetID: "b1", payeeID: "p1", limit: 25, offset: 50, token: "secret"
        )
        XCTAssertEqual(history.map(\.action), ["updated"])
        XCTAssertEqual(history.first?.beforeSnapshot?.displayName, "Market")
        XCTAssertEqual(history.first?.afterSnapshot.displayName, "Neighborhood Market")
        XCTAssertEqual(history.first?.actorDisplayName, "Owner")
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
            let response = Data(#"{"start_date":"2026-01-01","end_date":"2026-09-30","currency_code":"USD","opening_debt_minor":125000,"debt_minor":90001,"principal_reduction_minor":34999,"recorded_interest_range_minor":1234,"recorded_interest_month_minor":1234,"recorded_interest_ytd_minor":1234,"recorded_interest_trailing_12_minor":1234,"interest_tracking_started_on":"2026-09-15","points":[{"as_of":"2026-01-31","debt_minor":125000},{"as_of":"2026-09-30","debt_minor":90001,"net_debt_change_minor":34999,"recorded_interest_minor":1234}],"accounts":[{"account_id":"card","account_name":"Credit Card","account_type":"credit","is_on_budget":true,"debt_minor":90001,"recorded_interest_minor":1234}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.debtReport(budgetID: "b1", startDate: "2026-01-01", endDate: "2026-09-30", accountIDs: ["card"], token: "secret")
        XCTAssertEqual(report.openingDebtMinor, 125_000)
        XCTAssertEqual(report.debtMinor, 90_001)
        XCTAssertEqual(report.principalReductionMinor, 34_999)
        XCTAssertEqual(report.recordedInterestRangeMinor, 1_234)
        XCTAssertNil(report.recordedInterestLifetimeMinor, "Older responses must not invent an unreported all-history amount")
        XCTAssertEqual(report.interestTrackingStartedOn, "2026-09-15")
        XCTAssertEqual(report.points.map(\.debtMinor), [125_000, 90_001])
        XCTAssertNil(report.points.first?.netDebtChangeMinor, "Older point payloads remain readable")
        XCTAssertEqual(report.points.last?.netDebtChangeMinor, 34_999)
        XCTAssertEqual(report.points.last?.recordedInterestMinor, 1_234)
        XCTAssertEqual(report.accounts.first?.accountID, "card")
    }

    func testDebtStrategyProjectionUsesExactReadOnlyScenarioContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/debt-strategy-projection")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["strategy"] as? String, "custom")
            XCTAssertEqual(json["rollover"] as? Bool, true)
            XCTAssertEqual(json["extra_payment_minor"] as? Int, 10_000)
            XCTAssertEqual(json["account_ids"] as? [String], ["card", "loan"])
            XCTAssertEqual(json["custom_order"] as? [String], ["loan", "card"])
            XCTAssertEqual(json["target_date"] as? String, "2027-04-15")
            let response = Data(#"{"currency_code":"USD","status":"paid_off","strategy":"custom","rollover":true,"extra_payment_minor":10000,"payoff_order":["loan","card"],"debt_free_date":"2027-04-15","payment_count":16,"projected_interest_minor":12345,"projected_total_paid_minor":212345,"projected_total_cost_minor":212345,"accounts":[{"account_id":"card","payoff_date":"2027-04-15","payoff_month":16,"projected_interest_minor":10000,"projected_total_paid_minor":110000},{"account_id":"loan","payoff_date":"2026-12-15","payoff_month":12,"projected_interest_minor":2345,"projected_total_paid_minor":102345}],"incomplete_accounts":[],"target_date":"2027-04-15","required_extra_payment_minor":10000,"on_target":true}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let result = try await client.debtStrategyProjection(
            budgetID: "b1",
            request: .init(firstPaymentOn: "2026-01-15", strategy: "custom", rollover: true, extraPaymentMinor: 10_000, accountIDs: ["card", "loan"], customOrder: ["loan", "card"], targetDate: "2027-04-15"),
            token: "current-token"
        )
        XCTAssertEqual(result.status, "paid_off")
        XCTAssertEqual(result.payoffOrder, ["loan", "card"])
        XCTAssertEqual(result.projectedInterestMinor, 12_345)
        XCTAssertEqual(result.accounts.first?.accountID, "card")
        XCTAssertEqual(result.requiredExtraPaymentMinor, 10_000)
        XCTAssertEqual(result.onTarget, true)
    }

    func testDebtPayoffPlanUsesAuthoritativePersonalPlanContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/debt-payoff-plan")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            if request.httpMethod == "PUT" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                XCTAssertEqual(json["strategy"] as? String, "custom")
                XCTAssertEqual(json["extra_payment_minor"] as? Int, 12_345)
                XCTAssertEqual(json["account_ids"] as? [String], ["card", "loan"])
                XCTAssertEqual(json["custom_order"] as? [String], ["loan", "card"])
                XCTAssertEqual(json["target_date"] as? String, "2028-12-31")
            }
            if request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            let response = Data(#"{"id":"plan1","budget_id":"b1","user_id":"u1","strategy":"custom","rollover":true,"extra_payment_minor":12345,"account_ids":["card","loan"],"custom_order":["loan","card"],"target_date":"2028-12-31","updated_at":"2026-10-08T12:00:00Z"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let request = APIDebtPayoffPlanUpsert(strategy: "custom", rollover: true, extraPaymentMinor: 12_345, accountIDs: ["card", "loan"], customOrder: ["loan", "card"], targetDate: "2028-12-31")
        let saved = try await client.saveDebtPayoffPlan(budgetID: "b1", request: request, token: "current-token")
        XCTAssertEqual(saved.targetDate, "2028-12-31")
        let loaded = try await client.debtPayoffPlan(budgetID: "b1", token: "current-token")
        XCTAssertEqual(loaded, saved)
        try await client.deleteDebtPayoffPlan(budgetID: "b1", token: "current-token")
        XCTAssertEqual(methods, ["PUT", "GET", "DELETE"])
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
            let response = Data(#"{"as_of":"2026-09-01","through":"2026-10-01","currency_code":"USD","cash_buffer_minor":100000,"current_on_budget_minor":90000,"projected_on_budget_minor":110000,"lowest_projected_on_budget_minor":85000,"scheduled_income_minor":50000,"scheduled_outflows_minor":30000,"expected_margin_minor":20000,"average_age_of_money_days":42,"daily_burn_rate_minor":2500,"runway_days":40,"burn_rate_window_days":90,"essential_expense_coverage_days":null,"emergency_fund_coverage_days":null,"unavailable_metrics":{"essential_expense_coverage_days":"Classification unavailable."}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let report = try await client.resilienceReport(budgetID: "b1", token: "secret")
        XCTAssertEqual(report.cashBufferMinor, 100_000)
        XCTAssertEqual(report.expectedMarginMinor, 20_000)
        XCTAssertEqual(report.averageAgeOfMoneyDays, 42)
        XCTAssertEqual(report.dailyBurnRateMinor, 2_500)
        XCTAssertEqual(report.runwayDays, 40)
        XCTAssertEqual(report.burnRateWindowDays, 90)
        XCTAssertNil(report.essentialExpenseCoverageDays)
        XCTAssertEqual(report.unavailableMetrics["essential_expense_coverage_days"], "Classification unavailable.")
    }

    func testCategoryResilienceClassificationIsBackwardCompatibleAndEncodesExplicitly() throws {
        let legacy = Data(#"{"id":"c1","budget_id":"b1","group_id":"g1","name":"Rent","icon_name":null,"note":"","sort_order":0,"is_archived":false,"system_type":null,"linked_account_id":null,"delegated_user_id":null,"is_favorite":false,"favorite_sort_order":null}"#.utf8)
        let decoded = try JSONDecoder().decode(APICategory.self, from: legacy)
        XCTAssertFalse(decoded.isEssential)
        XCTAssertFalse(decoded.isEmergencyFund)

        let update = APICategoryUpdate(
            groupID: "g1", name: "Rent", isEssential: true, isEmergencyFund: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]
        )
        XCTAssertEqual(object["is_essential"] as? Bool, true)
        XCTAssertEqual(object["is_emergency_fund"] as? Bool, true)
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

    func testBudgetExportDownloadsStructuredJSONWithBearerCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/export.json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = Data(#"{"format":"clearpocket-budget-export","schema_version":2}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, response)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let data = try await client.budgetExportJSON(budgetID: "b1", token: "secret")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("clearpocket-budget-export"))
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

    func testScheduledHistoryUsesBoundedAttributedExactContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/scheduled-transactions/history")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(items.first(where: { $0.name == "offset" })?.value, "50")
            let data = Data(#"[{"id":"revision","schedule_id":"schedule","action":"realized","actor_user_id":"owner","actor_display_name":"Owner","before_snapshot":{"account_id":"checking","destination_account_id":null,"category_id":"groceries","payee_id":"market","name":"Groceries","amount_minor":-9007199254740992,"next_date":"2026-10-01","recurrence_unit":"months","interval_count":1,"end_date":null,"remaining_occurrences":null,"memo":"","financial_classification":null,"is_active":true,"last_realized_on":null},"after_snapshot":{"account_id":"checking","destination_account_id":null,"category_id":"groceries","payee_id":"market","name":"Groceries","amount_minor":-9007199254740992,"next_date":"2026-11-01","recurrence_unit":"months","interval_count":1,"end_date":null,"remaining_occurrences":null,"memo":"","financial_classification":null,"is_active":true,"last_realized_on":"2026-10-01"},"transaction_ids":["transaction"],"created_at":"2026-10-08T18:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let rows = try await client.scheduledTransactionHistory(budgetID: "b1", limit: 25, offset: 50, token: "rotated")
        XCTAssertEqual(rows.first?.afterSnapshot?.amountMinor, -9_007_199_254_740_992)
        XCTAssertEqual(rows.first?.transactionIDs, ["transaction"])
    }

    func testDelegatedPolicyHistoryUsesBoundedAttributedExactContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/delegated-budgets/member/history")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(items.first(where: { $0.name == "offset" })?.value, "50")
            let data = Data(#"[{"id":"revision","policy_id":"policy","member_user_id":"member","action":"updated","actor_user_id":"owner","actor_display_name":"Owner","before_snapshot":{"user_id":"member","pool_category_id":"pool","authority_minor":100,"allow_category_creation":true,"allow_reallocation":true,"rules":[]},"after_snapshot":{"user_id":"member","pool_category_id":"pool","authority_minor":9007199254740992,"allow_category_creation":false,"allow_reallocation":true,"rules":[{"category_id":"games","rule_kind":"hard_limit","minimum_minor":123,"maximum_minor":null}]},"created_at":"2026-10-08T18:00:00Z"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)
        let rows = try await client.delegatedBudgetHistory(budgetID: "b1", userID: "member", limit: 25, offset: 50, token: "rotated")
        XCTAssertEqual(rows.first?.afterSnapshot.authorityMinor, 9_007_199_254_740_992)
        XCTAssertEqual(rows.first?.afterSnapshot.rules.first?.categoryID, "games")
        XCTAssertEqual(rows.first?.actorDisplayName, "Owner")
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
                XCTAssertEqual(json["remaining_occurrences"] as? Int, 6)
            }
            let body = Data(#"{"id":"s1","budget_id":"b1","account_id":"a1","destination_account_id":null,"category_id":"c1","payee_id":"p1","name":"Netflix","amount_minor":-1599,"next_date":"2026-10-01","recurrence_unit":"months","interval_count":1,"remaining_occurrences":6,"memo":"","is_active":true,"last_realized_on":null}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 201 : 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let created = try await client.createScheduledTransaction(budgetID: "b1", schedule: APIScheduledTransactionCreate(accountID: "a1", categoryID: "c1", payeeID: "p1", name: "Netflix", amountMinor: -1599, nextDate: "2026-10-01", recurrenceUnit: "months", remainingOccurrences: 6), token: "secret")
        XCTAssertEqual(created.id, "s1")
        XCTAssertEqual(created.payeeID, "p1")
        XCTAssertEqual(created.recurrenceUnit, "months")
        XCTAssertEqual(created.remainingOccurrences, 6)

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

    func testBackupHealthUsesOwnerScopedBudgetRouteAndDecodesRecoveryMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/backup-status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
            let body = Data(#"{"configured":true,"backup":{"state":"publication_failed","archive":"/private/backup.age","completed_at":"2026-09-27T14:00:00Z","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":9007199254740993,"destination":{"destination":"local_generation","path":"/private/backup.age"},"error":"Off-device backup publication failed"},"last_successful_backup":{"state":"healthy","archive":"/private/prior.age","completed_at":"2026-09-27T12:00:00Z","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":8000,"destination":{"destination":"dropbox","path":"/Backups/prior.age","size":8000,"content_hash":"hash"}},"schedule":{"state":"enabled","provider":"systemd","frequency":"daily","hour":3,"minute":15,"retention":12,"updated_at":"2026-09-27T11:00:00Z"},"last_restore_verification":{"state":"verified","verified_at":"2026-09-27T13:00:00Z","source_provider":"portable_archive","source_archive_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","database_integrity":"ok","foreign_keys":"ok"}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let result = try await client.backupStatus(budgetID: "b1", token: "rotated")

        XCTAssertTrue(result.configured)
        XCTAssertEqual(result.backup.size, 9_007_199_254_740_993)
        XCTAssertEqual(result.backup.destination?.destination, "local_generation")
        XCTAssertEqual(result.lastSuccessfulBackup?.destination?.destination, "dropbox")
        XCTAssertEqual(result.lastSuccessfulBackup?.completedAt, "2026-09-27T12:00:00Z")
        XCTAssertEqual(result.schedule?.provider, "systemd")
        XCTAssertEqual(result.schedule?.hour, 3)
        XCTAssertEqual(result.schedule?.retention, 12)
        XCTAssertEqual(result.lastRestoreVerification?.sourceProvider, "portable_archive")
        XCTAssertEqual(result.lastRestoreVerification?.databaseIntegrity, "ok")
    }

    func testLocalDeviceTransferEligibilityUsesOwnerRouteAndDecodesLosslessBlockers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/local-device-transfer-eligibility")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            let body = Data(#"{"target_provider":"local_device","eligible":false,"budget_id":"b1","budget_name":"Family","blockers":[{"code":"shared_household_history","title":"Shared history requires Budget Server.","record_count":2}],"source_unchanged":true,"requires_new_local_authority":true}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let result = try await client.localDeviceTransferEligibility(budgetID: "b1", token: "current")

        XCTAssertFalse(result.eligible)
        XCTAssertEqual(result.targetProvider, "local_device")
        XCTAssertEqual(result.blockers.first?.code, "shared_household_history")
        XCTAssertEqual(result.blockers.first?.recordCount, 2)
        XCTAssertTrue(result.sourceUnchanged)
        XCTAssertTrue(result.requiresNewLocalAuthority)
    }

    func testLocalDeviceTransferProjectionDownloadsOpaqueAuthenticatedContract() async throws {
        let body = Data(#"{"format":"com.clearpocket.local-device-transfer","version":1}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(
            baseURL: URL(string: "https://budget.example.com")!,
            session: URLSession(configuration: configuration)
        )

        let result = try await client.localDeviceTransferProjectionData(
            budgetID: "budget-1", token: "rotated-current-token"
        )

        XCTAssertEqual(result, body)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/api/v1/budgets/budget-1/local-device-transfer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-current-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testStatementImportUploadsOpaqueFileThenApprovesTypedReview() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var requests = 0
        let responseBody = Data(#"{"id":"batch-1","budget_id":"b1","account_id":"a1","status":"review","version":0,"source_format":"csv","candidate_count":1,"candidates":[{"source_row":2,"occurred_on":"2026-09-15","amount_minor":-1234,"payee":"Market","memo":"Food","exact_transaction_ids":[],"possible_transaction_ids":[],"suggestions_truncated":false,"duplicate_source_row":null,"suggested_category_id":"c1","approval_action":null,"posted_transaction_id":null}],"created_at":"2026-10-02T12:00:00Z"}"#.utf8)
        MockURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            if requests == 1 {
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Statement-Format"), "csv")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSV-Date-Column"), "Date")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSV-Number-Format"), "comma_decimal")
                XCTAssertEqual(try requestBody(request), Data("Date,Amount,Payee\n".utf8))
            } else {
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports/batch-1/approve")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertEqual(body["expected_version"] as? Int, 0)
                let items = body["items"] as! [[String: Any]]
                XCTAssertEqual(items.first?["source_row"] as? Int, 2)
                XCTAssertEqual(items.first?["category_id"] as? String, "c1")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: requests == 1 ? 201 : 200, httpVersion: nil, headerFields: nil)!, responseBody)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let staged = try await client.stageStatementImport(
            budgetID: "b1", accountID: "a1", data: Data("Date,Amount,Payee\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd", numberFormat: "comma_decimal"), token: "current"
        )
        XCTAssertEqual(staged.candidates.first?.amountMinor, -1234)
        XCTAssertEqual(staged.candidates.first?.suggestedCategoryID, "c1")
        _ = try await client.approveStatementImport(
            budgetID: "b1", accountID: "a1", batchID: staged.id,
            approval: .init(expectedVersion: 0, items: [.init(sourceRow: 2, action: "post", categoryID: "c1")]), token: "current"
        )
        XCTAssertEqual(requests, 2)
    }

    func testStatementImportCancellationSendsOnlyOptimisticVersion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let responseBody = Data(#"{"id":"batch-1","budget_id":"b1","account_id":"a1","status":"cancelled","version":4,"source_format":"csv","candidate_count":0,"candidates":[],"created_at":"2026-10-02T12:00:00Z"}"#.utf8)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports/batch-1/cancel")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual(body["expected_version"] as? Int, 3)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseBody)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let result = try await client.cancelStatementImport(
            budgetID: "b1", accountID: "a1", batchID: "batch-1", expectedVersion: 3, token: "current"
        )
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertEqual(result.version, 4)
    }

    func testStatementImportUndoSendsOnlyOptimisticVersion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let responseBody = Data(#"{"id":"batch-1","budget_id":"b1","account_id":"a1","status":"approved","version":2,"source_format":"csv","candidate_count":1,"candidates":[{"source_row":2,"occurred_on":"2026-10-02","amount_minor":-100,"payee":"Cafe","memo":"","exact_transaction_ids":[],"possible_transaction_ids":[],"suggestions_truncated":false,"duplicate_source_row":null,"approval_action":"post","posted_transaction_id":"t1","reversal_transaction_id":"r1"}],"created_at":"2026-10-02T12:00:00Z"}"#.utf8)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports/batch-1/undo")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual(body["expected_version"] as? Int, 1)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseBody)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let result = try await client.undoStatementImport(
            budgetID: "b1", accountID: "a1", batchID: "batch-1", expectedVersion: 1, token: "current"
        )
        XCTAssertEqual(result.candidates.first?.reversalTransactionID, "r1")
        XCTAssertEqual(result.version, 2)
    }

    func testStatementImportHistoryIsBoundedAndDetailLoadsSeparately() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current")
            if requests == 1 {
                XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports")
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "limit" })?.value, "25")
                XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "offset" })?.value, "0")
                let body = Data(#"{"items":[{"id":"batch-1","budget_id":"b1","account_id":"a1","status":"review","version":0,"source_format":"csv","candidate_count":1,"created_at":"2026-10-02T12:00:00Z"}],"has_more":false,"next_offset":null}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/budgets/b1/accounts/a1/statement-imports/batch-1")
            let body = Data(#"{"id":"batch-1","budget_id":"b1","account_id":"a1","status":"review","version":0,"source_format":"csv","candidate_count":1,"candidates":[{"source_row":2,"occurred_on":"2026-09-15","amount_minor":-1234,"payee":"Private","memo":"Private memo","exact_transaction_ids":[],"possible_transaction_ids":[],"suggestions_truncated":false,"duplicate_source_row":null,"approval_action":null,"posted_transaction_id":null}],"created_at":"2026-10-02T12:00:00Z"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: URLSession(configuration: configuration))
        let page = try await client.statementImports(budgetID: "b1", accountID: "a1", token: "current")
        XCTAssertEqual(page.items.map(\.id), ["batch-1"])
        let detail = try await client.statementImport(budgetID: "b1", accountID: "a1", batchID: "batch-1", token: "current")
        XCTAssertEqual(detail.candidates.first?.payee, "Private")
        XCTAssertEqual(requests, 2)
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
