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
            let body = Data(#"[{"id":"b1","household_id":"h1","name":"Family","currency_code":"USD"}]"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = try APIClient(baseURL: URL(string: "https://budget.example.com")!, session: session)

        let budgets = try await client.budgets(token: "secret")

        XCTAssertEqual(budgets, [APIBudget(id: "b1", householdID: "h1", name: "Family", currencyCode: "USD")])
    }
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
