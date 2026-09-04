import XCTest
@testable import BudgetCore

final class AuthorizationTests: XCTestCase {
    private let householdID = HouseholdID()
    private let ownerID = UserID()
    private let sonID = UserID()
    private let daughterID = UserID()
    private let authorizer = BudgetAuthorizer()

    func testOwnerCanAccessEveryHouseholdBudgetWithoutExplicitGrant() {
        let budget = Budget(householdID: householdID, name: "Family")
        let owner = HouseholdMember(
            userID: ownerID,
            householdID: householdID,
            role: .owner
        )

        XCTAssertEqual(
            authorizer.authorize(member: owner, budget: budget, grants: [], action: .changeSharing),
            .allowed
        )
    }

    func testChildCannotDiscoverSiblingBudgetWithoutGrant() {
        let daughterBudget = Budget(householdID: householdID, name: "Daughter")
        let son = HouseholdMember(
            userID: sonID,
            householdID: householdID,
            role: .child
        )
        let grants = [
            BudgetGrant(budgetID: daughterBudget.id, userID: daughterID, permission: .manage)
        ]

        XCTAssertEqual(
            authorizer.authorize(member: son, budget: daughterBudget, grants: grants, action: .view),
            .notFound
        )
        XCTAssertTrue(
            authorizer.visibleBudgets(for: son, budgets: [daughterBudget], grants: grants).isEmpty
        )
    }

    func testContributorCanAddTransactionsButCannotChangeSharing() {
        let allowance = Budget(householdID: householdID, name: "Son allowance")
        let son = HouseholdMember(
            userID: sonID,
            householdID: householdID,
            role: .child
        )
        let grants = [
            BudgetGrant(budgetID: allowance.id, userID: sonID, permission: .contribute)
        ]

        XCTAssertEqual(
            authorizer.authorize(member: son, budget: allowance, grants: grants, action: .addTransaction),
            .allowed
        )
        XCTAssertEqual(
            authorizer.authorize(member: son, budget: allowance, grants: grants, action: .changeSharing),
            .forbidden
        )
    }

    func testInactiveMemberCannotDiscoverPreviouslySharedBudget() {
        let budget = Budget(householdID: householdID, name: "Family")
        let inactiveSon = HouseholdMember(
            userID: sonID,
            householdID: householdID,
            role: .child,
            isActive: false
        )
        let grants = [
            BudgetGrant(budgetID: budget.id, userID: sonID, permission: .manage)
        ]

        XCTAssertEqual(
            authorizer.authorize(member: inactiveSon, budget: budget, grants: grants, action: .view),
            .notFound
        )
    }
}

