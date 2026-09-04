import Foundation

struct TokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

public struct APIBudget: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let householdID: String
    public let name: String
    public let currencyCode: String

    public init(id: String, householdID: String, name: String, currencyCode: String) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.currencyCode = currencyCode
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case householdID = "household_id"
        case currencyCode = "currency_code"
    }
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

public struct BootstrapRequest: Encodable, Sendable {
    let email: String
    let password: String
    let displayName: String
    let householdName: String

    public init(email: String, password: String, displayName: String, householdName: String) {
        self.email = email
        self.password = password
        self.displayName = displayName
        self.householdName = householdName
    }

    enum CodingKeys: String, CodingKey {
        case email, password
        case displayName = "display_name"
        case householdName = "household_name"
    }
}

struct APIErrorBody: Decodable {
    let detail: String?
}
