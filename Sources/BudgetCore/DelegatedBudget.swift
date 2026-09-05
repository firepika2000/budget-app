import Foundation

public enum DelegatedRuleKind: String, Codable, Sendable {
    case hardLimit
    case softTarget
    case approvalGated
}

public struct DelegatedCategoryBalance: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String
    public var assignedMinor: Int64
    public var minimumMinor: Int64?
    public var maximumMinor: Int64?
    public var withdrawalRule: DelegatedRuleKind?

    public init(
        id: String,
        name: String,
        assignedMinor: Int64,
        minimumMinor: Int64? = nil,
        maximumMinor: Int64? = nil,
        withdrawalRule: DelegatedRuleKind? = nil
    ) {
        self.id = id
        self.name = name
        self.assignedMinor = assignedMinor
        self.minimumMinor = minimumMinor
        self.maximumMinor = maximumMinor
        self.withdrawalRule = withdrawalRule
    }
}

public struct DelegatedBudgetState: Equatable, Codable, Sendable {
    public let memberID: String
    public var authorityMinor: Int64
    public var categories: [DelegatedCategoryBalance]

    public init(memberID: String, authorityMinor: Int64, categories: [DelegatedCategoryBalance]) {
        self.memberID = memberID
        self.authorityMinor = authorityMinor
        self.categories = categories
    }

    public var assignedMinor: Int64 { categories.reduce(0) { $0 + $1.assignedMinor } }
    public var availableToAssignMinor: Int64 { authorityMinor - assignedMinor }
}

public enum DelegatedBudgetError: Error, Equatable, Sendable {
    case invalidAmount
    case invalidAuthority
    case duplicateCategory
    case categoryNotFound
    case insufficientSource
    case exceedsAuthority
    case exceedsCategoryMaximum(categoryID: String, maximumMinor: Int64)
    case violatesCategoryMinimum(categoryID: String, minimumMinor: Int64)
    case requiresApproval(categoryID: String)
}

public struct DelegatedBudgetService: Sendable {
    public init() {}

    public func validate(_ state: DelegatedBudgetState) throws {
        guard state.authorityMinor >= 0 else { throw DelegatedBudgetError.invalidAuthority }
        guard Set(state.categories.map(\.id)).count == state.categories.count else {
            throw DelegatedBudgetError.duplicateCategory
        }
        guard state.categories.allSatisfy({ $0.assignedMinor >= 0 }) else {
            throw DelegatedBudgetError.invalidAmount
        }
        guard state.assignedMinor <= state.authorityMinor else {
            throw DelegatedBudgetError.exceedsAuthority
        }
        for category in state.categories {
            if let maximum = category.maximumMinor, category.assignedMinor > maximum {
                throw DelegatedBudgetError.exceedsCategoryMaximum(categoryID: category.id, maximumMinor: maximum)
            }
            if category.withdrawalRule == .hardLimit,
               let minimum = category.minimumMinor,
               category.assignedMinor < minimum {
                throw DelegatedBudgetError.violatesCategoryMinimum(categoryID: category.id, minimumMinor: minimum)
            }
        }
    }

    public func createCategory(
        in state: DelegatedBudgetState,
        id: String,
        name: String,
        initialAssignmentMinor: Int64 = 0
    ) throws -> DelegatedBudgetState {
        guard initialAssignmentMinor >= 0 else { throw DelegatedBudgetError.invalidAmount }
        guard !state.categories.contains(where: { $0.id == id }) else {
            throw DelegatedBudgetError.duplicateCategory
        }
        var result = state
        result.categories.append(.init(id: id, name: name, assignedMinor: initialAssignmentMinor))
        try validate(result)
        return result
    }

    public func move(
        in state: DelegatedBudgetState,
        amountMinor: Int64,
        from sourceID: String?,
        to destinationID: String
    ) throws -> DelegatedBudgetState {
        guard amountMinor > 0 else { throw DelegatedBudgetError.invalidAmount }
        guard let destinationIndex = state.categories.firstIndex(where: { $0.id == destinationID }) else {
            throw DelegatedBudgetError.categoryNotFound
        }
        var result = state

        if let sourceID {
            guard let sourceIndex = result.categories.firstIndex(where: { $0.id == sourceID }) else {
                throw DelegatedBudgetError.categoryNotFound
            }
            guard result.categories[sourceIndex].assignedMinor >= amountMinor else {
                throw DelegatedBudgetError.insufficientSource
            }
            if result.categories[sourceIndex].withdrawalRule == .approvalGated {
                throw DelegatedBudgetError.requiresApproval(categoryID: sourceID)
            }
            result.categories[sourceIndex].assignedMinor -= amountMinor
        } else {
            guard result.availableToAssignMinor >= amountMinor else {
                throw DelegatedBudgetError.exceedsAuthority
            }
        }

        result.categories[destinationIndex].assignedMinor += amountMinor
        try validate(result)
        return result
    }
}
