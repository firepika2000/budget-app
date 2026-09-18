import Foundation

public enum APICashRolloverPolicy: String, Codable, CaseIterable, Sendable {
    case carryCategoryDeficit = "carry_category_deficit"
    case absorbNextMonth = "absorb_next_month"
}

public struct APICashRolloverPendingPolicy: Decodable, Equatable, Sendable {
    public let effectiveMonth: String
    public let policy: APICashRolloverPolicy
    public let version: Int
    enum CodingKeys: String, CodingKey { case effectiveMonth = "effective_month", policy, version }
}

public struct APICashRolloverPolicyObservation: Decodable, Equatable, Sendable {
    public let currentMonth: String
    public let currentPolicy: APICashRolloverPolicy
    public let policyVersion: Int
    public let allocationVersion: Int
    public let pending: [APICashRolloverPendingPolicy]
    enum CodingKeys: String, CodingKey {
        case currentMonth = "current_month", currentPolicy = "current_policy"
        case policyVersion = "policy_version", allocationVersion = "allocation_version", pending
    }
}

public struct APICashRolloverPolicySelection: Encodable, Equatable, Sendable {
    public let policy: APICashRolloverPolicy
    public let effectiveMonth: String
    public let expectedPolicyVersion: Int
    public let expectedAllocationVersion: Int
    public init(policy: APICashRolloverPolicy, effectiveMonth: String, expectedPolicyVersion: Int, expectedAllocationVersion: Int) {
        self.policy = policy; self.effectiveMonth = effectiveMonth
        self.expectedPolicyVersion = expectedPolicyVersion; self.expectedAllocationVersion = expectedAllocationVersion
    }
    enum CodingKeys: String, CodingKey {
        case policy, effectiveMonth = "effective_month"
        case expectedPolicyVersion = "expected_policy_version", expectedAllocationVersion = "expected_allocation_version"
    }
}

public struct APICashRolloverPolicyAudit: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let effectiveMonth: String
    public let policy: APICashRolloverPolicy
    public let version: Int
    public let source: String
    public let actorUserID: String?
    public let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, policy, version, source, effectiveMonth = "effective_month"
        case actorUserID = "actor_user_id", createdAt = "created_at"
    }
}

public struct APICashRolloverPolicyHistory: Decodable, Equatable, Sendable {
    public let items: [APICashRolloverPolicyAudit]
    public let nextBeforeVersion: Int?
    enum CodingKeys: String, CodingKey { case items, nextBeforeVersion = "next_before_version" }
}
