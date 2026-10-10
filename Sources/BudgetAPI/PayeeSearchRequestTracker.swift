import Foundation

/// A query may repeat while an older request is still in flight. Compare request
/// identity as well as query and authority before publishing any completion.
public struct PayeeSearchRequestTracker {
    public struct Request: Equatable {
        public let id: UUID
        public let query: String
        public let authority: Int
    }
    private var current: Request?
    public init() {}
    public mutating func begin(query: String, authority: Int) -> Request {
        let request = Request(id: UUID(), query: query, authority: authority)
        current = request
        return request
    }
    public func accepts(_ request: Request, query: String, authority: Int) -> Bool {
        current == request && request.query == query && request.authority == authority
    }
    public mutating func invalidate() { current = nil }
}
