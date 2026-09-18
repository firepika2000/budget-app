import Foundation
import SwiftUI
import BudgetCore

@MainActor
final class DemoStore: ObservableObject {
    @Published var persona: DemoPersona = .rey
    @Published var hideAmounts = false
    @Published var accounts: [DemoAccount]
    @Published var categories: [DemoCategory]
    @Published var transactions: [DemoTransaction]
    @Published var payees: [DemoPayee]
    @Published var schedules: [DemoSchedule]
    @Published var requests: [DemoRequest]
    @Published var allowances: [DemoAllowance]
    @Published var groupOrder: [String]
    @Published var archivedGroups = Set<String>()
    @Published var selectedMonth = "September 2026"
    @Published private(set) var unassignedMinor: Int64 = 0
    @Published var errorMessage: String?
    private var reserveAttribution: [String: [String: Int64]] = [:]
    private(set) var fixtureOpening: PlanningPeriodProjection.Opening?
    private(set) var fixtureAccountOpening: [String: Int64] = [:]
    // Repository-loaded effective history. Public policy commands/defaults are integrated
    // separately; an absent history preserves the legacy carry policy.
    let cashRolloverPolicies: [CashRolloverProjection.Change]

    struct AllocationEvent {
        let id: String
        let operationID: String
        let occurredOn: String
        let kind: String
        let actor: String
        let note: String
        let sourceCategoryID: String?
        let destinationCategoryID: String
        let amountMinor: Int64
    }
    // Command history only. Seed opening observations are not invented historical operations.
    private(set) var allocationEvents: [AllocationEvent] = []
    private(set) var allocationVersion = 0

    func requireAllocationVersion(_ expected: Int) throws {
        guard expected == allocationVersion else {
            throw NSError(domain: "BudgetWorkspace", code: 409, userInfo: [NSLocalizedDescriptionKey: "Allocations changed. Refresh before trying again."])
        }
    }

    func recordAllocation(amount: Int64, from source: String? = nil, to destination: String,
                          occurredOn: String = BudgetWorkspaceStore.dateString(Date()),
                          kind: String = "assignment", note: String = "", id: String = UUID().uuidString) {
        guard amount != 0 else { return }
        allocationEvents.append(.init(id: id, operationID: id, occurredOn: occurredOn, kind: kind,
                                     actor: persona.rawValue.lowercased(), note: note,
                                     sourceCategoryID: source, destinationCategoryID: destination,
                                     amountMinor: amount))
        allocationVersion += 1
    }

    // Validate the whole operation before publishing any state. All legs share one identity
    // and consume one optimistic concurrency token, like Live append_operation.
    func fundTargets(_ amounts: [(categoryID: String, amount: Int64)], month: String, expectedVersion: Int) throws {
        guard !isRestricted else { throw DemoMutationError.restrictedCategory }
        try requireAllocationVersion(expectedVersion)
        guard !amounts.isEmpty, Set(amounts.map(\.categoryID)).count == amounts.count else { throw DemoMutationError.invalidAmount }
        for item in amounts {
            guard item.amount > 0 else { throw DemoMutationError.invalidAmount }
            guard categories.contains(where: { $0.id == item.categoryID && !$0.isHidden && !archivedGroups.contains($0.group) }) else { throw DemoMutationError.categoryNotFound }
        }
        let total = try Money.sumMinorUnits(amounts.map(\.amount))
        let selected = try planningSnapshot(month: month)
        guard total <= selected.fundingLimitMinor else { throw DemoMutationError.insufficientFunds(available: selected.fundingLimitMinor) }
        let allocation = try PlanningPeriodProjection.Allocation(occurredOn: month, postings:
            [.init(categoryID: nil, amountMinor: -total)] + amounts.map { .init(categoryID: $0.categoryID, amountMinor: $0.amount) })
        _ = try planningSnapshot(month: month, additionalAllocations: [allocation])
        let current = try planningSnapshot(month: currentPlanningMonth, additionalAllocations: [allocation])
        let operationID = UUID().uuidString
        let events = amounts.map { item in
            AllocationEvent(id: UUID().uuidString, operationID: operationID, occurredOn: month,
                            kind: "smart_funding", actor: persona.rawValue.lowercased(), note: "",
                            sourceCategoryID: nil, destinationCategoryID: item.categoryID, amountMinor: item.amount)
        }
        allocationEvents.append(contentsOf: events)
        allocationVersion += 1
        publishPlanning(current)
    }

    let incomeHistory: [Int64] = [725000, 738000, 725000, 760000, 742000, 750000]
    let spendingHistory: [Int64] = [594000, 621000, 609000, 642000, 598000, 634000]
    let netWorthHistory: [Int64] = [12840000, 12976000, 13112000, 13200000, 13358000, 13593000]

    init(fresh: Bool = false, cashRolloverPolicies: [CashRolloverProjection.Change] = []) {
        self.cashRolloverPolicies = cashRolloverPolicies
        accounts = []; categories = []; transactions = []; payees = []
        schedules = []; requests = []; allowances = []; groupOrder = []
        if !fresh { installSeedLedger() }
    }

    var isRestricted: Bool { persona.isChild }
    var visibleAccounts: [DemoAccount] { isRestricted ? accounts.filter { !$0.restrictedFromChildren } : accounts }
    var visibleCategories: [DemoCategory] {
        guard isRestricted else { return categories.filter { !$0.isHidden && !archivedGroups.contains($0.group) } }
        return categories.filter { $0.delegatedTo == persona && !$0.isHidden && !archivedGroups.contains($0.group) }
    }
    var visibleTransactions: [DemoTransaction] {
        guard isRestricted else { return transactions }
        let allowed = Set(visibleCategories.map(\.id))
        return transactions.filter { $0.member == persona && !Set($0.categoryIDs).isDisjoint(with: allowed) }
    }
    var readyToAssign: Int64 { isRestricted ? 0 : unassignedMinor }
    var delegatedAuthority: Int64 { persona == .alex ? 20_000 : persona == .mia ? 12_000 : 0 }
    var delegatedAssigned: Int64 { visibleCategories.reduce(0) { $0 + max($1.assigned, 0) } }
    var delegatedReadyToAssign: Int64 { max(delegatedAuthority - delegatedAssigned, 0) }
    var availableToSpend: Int64 { visibleCategories.filter { $0.group == "Kids" || $0.group == "Personal" }.reduce(0) { $0 + max($1.available, 0) } }
    var netWorth: Int64 { accounts.reduce(0) { $0 + $1.balance } }
    var pendingRequests: [DemoRequest] { requests.filter { $0.status == "Pending" } }
    var overspent: [DemoCategory] { visibleCategories.filter { $0.available < 0 } }
    var underfunded: [DemoCategory] { visibleCategories.filter { $0.target != nil && $0.available >= 0 && $0.progress < 1 } }

    func financialObservation(accountReferences: [String: String], categoryReferences: [String: String]) -> FinancialObservation {
        let accountValues = accountReferences.compactMapValues { id in
            accounts.first(where: { $0.id == id }).map { AccountBalanceObservation(balanceMinor: $0.balance) }
        }
        let categoryValues = categoryReferences.compactMapValues { id in
            categories.first(where: { $0.id == id }).map {
                CategoryBalanceObservation(assignedMinor: $0.assigned, activityMinor: $0.activity, availableMinor: $0.available)
            }
        }
        let cards = accountReferences.compactMapValues { id -> CreditCardObservation? in
            guard let account = accounts.first(where: { $0.id == id }), account.kind == .credit else { return nil }
            let liability = max(-account.balance, 0)
            return CreditCardObservation(liabilityMinor: liability, reservedMinor: account.paymentReserved,
                                         unfundedDebtMinor: max(liability - account.paymentReserved, 0))
        }
        let budgetCash = accounts.filter { $0.isOnBudget && [.checking, .savings, .cash].contains($0.kind) }.reduce(Int64(0)) { $0 + $1.balance }
        let allocationDifference = allocationEvents.reduce(Int64(0)) { total, event in
            total + (-event.amountMinor + event.amountMinor)
        }
        return FinancialObservation(accounts: accountValues, categories: categoryValues, cards: cards,
                                    unassignedMinor: unassignedMinor, totalBudgetCashMinor: budgetCash,
                                    netWorthMinor: netWorth, transactionCount: transactions.count,
                                    allocationPostingsSumMinor: allocationDifference)
    }

    func money(_ amount: Int64) -> String { hideAmounts ? "••••" : amount.demoCurrency }

    func reset() {
        persona = .rey
        hideAmounts = false
        archivedGroups = []
        installSeedLedger()
    }

    /// A complete deterministic opening plus chronological fixture commands. No differences
    /// between independent display totals are reclassified as income or invented transactions.
    private func installSeedLedger() {
        accounts = Self.seedAccounts
        categories = Self.seedCategories
        transactions = []
        payees = Self.seedPayees
        schedules = Self.seedSchedules
        requests = Self.seedRequests
        allowances = Self.seedAllowances
        groupOrder = Array(Set(Self.seedCategories.map(\.group))).sorted()
        reserveAttribution = [:]
        allocationEvents = []
        allocationVersion = 0
        fixtureAccountOpening = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.balance) })
        let openingAvailable: [String: Int64] = [
            "emergency": 800_000, "newcar": 300_000, "vacation": 200_000, "repair": 100_000,
            "medical": 40_000, "christmas": 70_000, "subscriptions": 60_000,
            "maintenance": 100_000, "cnc": 40_000, "alexsave": 20_000, "miabike": 20_000,
        ]
        let openingCash = accounts.filter { $0.isOnBudget && [.checking, .savings, .cash].contains($0.kind) }.reduce(Int64(0)) { $0 + $1.balance }
        unassignedMinor = openingCash - openingAvailable.values.reduce(0, +)
        for index in categories.indices {
            categories[index].assigned = 0; categories[index].activity = 0
            categories[index].available = openingAvailable[categories[index].id] ?? 0
        }
        do {
            fixtureOpening = try .init(month: "2025-10-01", unassignedMinor: unassignedMinor, categoryAvailable: openingAvailable)
            let posted = Self.seedTransactions.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            for offset in (0...11).reversed() {
                let month = String(BudgetWorkspaceStore.dateString(.demo(monthsAgo: offset, day: 1)).prefix(7)) + "-01"
                let activity = posted.filter { String(BudgetWorkspaceStore.dateString($0.date).prefix(7)) == String(month.prefix(7)) }
                // Historical fixture months deliberately fund each demonstrated expense. Current
                // month uses the explicit plan below, including an overspent dining category.
                var assignments: [String: Int64] = [:]
                if offset == 0 {
                    assignments = Dictionary(uniqueKeysWithValues: Self.seedCategories.map { ($0.id, $0.assigned) })
                } else {
                    for item in activity {
                        for (id, amount) in canonicalCategoryAmounts(for: item) { assignments[id, default: 0] += max(-amount, 0) }
                    }
                }
                for id in assignments.keys.sorted() {
                    let amount = assignments[id]!
                    guard amount > 0, let index = categories.firstIndex(where: { $0.id == id }) else { continue }
                    precondition(amount <= unassignedMinor, "Fixture allocations require real opening cash")
                    unassignedMinor -= amount
                    categories[index].assigned += amount; categories[index].available += amount
                    recordAllocation(amount: amount, to: id, occurredOn: month, note: "Deterministic fixture assignment", id: "fixture-\(month)-\(id)")
                }
                for item in activity {
                    try applyCanonicalTransaction(item)
                    transactions.append(item)
                }
            }
            transactions.sort { ($0.date, $0.id) > ($1.date, $1.id) }
            let plan = try fixturePlanningSnapshot(month: "2026-09-01")
            for index in categories.indices {
                let row = plan.categories[categories[index].id]!
                categories[index].assigned = row.assignedMinor
                categories[index].activity = row.activityMinor
                categories[index].available = row.availableMinor
            }
            if !cashRolloverPolicies.contains(where: { $0.policy == .absorb }) {
                precondition(plan.allDateUnassignedMinor == unassignedMinor, "Fixture command and period projections must agree")
            }
            publishPlanning(plan)
        } catch { preconditionFailure("Invalid deterministic financial fixture: \(error)") }
    }

    /// Fixture proof uses the same dated facts/projection as ordinary production reads and commands.
    func fixturePlanningSnapshot(month: String) throws -> PlanningPeriodProjection.Snapshot {
        try planningSnapshot(month: month)
    }

    var currentPlanningMonth: String { String(BudgetWorkspaceStore.dateString(Date()).prefix(7)) + "-01" }

    func planningSnapshot(month: String, through: String? = nil,
                          additionalAllocations: [PlanningPeriodProjection.Allocation] = []) throws -> PlanningPeriodProjection.Snapshot {
        let allocations = try allocationEvents.map { event in
            try PlanningPeriodProjection.Allocation(occurredOn: event.occurredOn, postings: [
                .init(categoryID: event.sourceCategoryID, amountMinor: -event.amountMinor),
                .init(categoryID: event.destinationCategoryID, amountMinor: event.amountMinor),
            ])
        }
        // Voiding keeps the original financial fact and adds an opposite dated reversal.
        // Removing the original here would count only the refund and manufacture category money.
        let activity = try transactions.filter { !$0.scheduled && (through == nil || BudgetWorkspaceStore.dateString($0.date) <= through!) }.map { item in
            guard let account = accounts.first(where: { $0.id == item.accountID }) else { throw DemoMutationError.accountNotFound }
            let amounts = item.transferID == nil && account.isOnBudget ? canonicalCategoryAmounts(for: item) : [:]
            let cashInflow = item.transferID == nil && amounts.isEmpty && account.isOnBudget && [.checking, .savings, .cash].contains(account.kind)
            return try PlanningPeriodProjection.PostedActivity(occurredOn: BudgetWorkspaceStore.dateString(item.date), categoryAmounts: amounts, unassignedMinor: cashInflow ? item.amount : 0)
        }
        let datedAllocations = (allocations + additionalAllocations).filter { through == nil || $0.occurredOn.iso <= through! }
        var effects: [CashRolloverProjection.Effect] = []
        if cashRolloverPolicies.contains(where: { $0.policy == .absorb }) {
            var facts: [CashRolloverProjection.Fact] = []
            if let opening = fixtureOpening {
                for (categoryID, amount) in opening.categoryAvailable {
                    facts.append(try .init(occurredOn: opening.month.iso, categoryID: categoryID, availableDeltaMinor: amount))
                }
            }
            for allocation in datedAllocations {
                for posting in allocation.postings {
                    if let categoryID = posting.categoryID {
                        facts.append(try .init(occurredOn: allocation.occurredOn.iso, categoryID: categoryID, availableDeltaMinor: posting.amountMinor))
                    }
                }
            }
            let accountByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            for item in transactions where !item.scheduled && item.transferID == nil {
                let day = BudgetWorkspaceStore.dateString(item.date)
                guard through == nil || day <= through!, let account = accountByID[item.accountID], account.isOnBudget else { continue }
                for (categoryID, amount) in canonicalCategoryAmounts(for: item) {
                    facts.append(try .init(occurredOn: day, categoryID: categoryID, availableDeltaMinor: amount,
                                           unfundedCreditDeltaMinor: account.kind == .credit ? amount : 0))
                }
                if account.kind == .credit {
                    for (categoryID, amount) in recordedReserveAmounts(transactionID: item.id) {
                        facts.append(try .init(occurredOn: day, categoryID: categoryID, availableDeltaMinor: 0, unfundedCreditDeltaMinor: amount))
                    }
                }
            }
            effects = try CashRolloverProjection.effects(throughMonth: through.map { String($0.prefix(7)) + "-01" } ?? "9999-12-01",
                                                        policies: cashRolloverPolicies, facts: facts)
        }
        return try PlanningPeriodProjection.snapshot(month: month, categoryIDs: Set(categories.map(\.id)), opening: fixtureOpening, allocations: datedAllocations, activity: activity, rolloverEffects: effects)
    }

    func projectedCategories(month: String) throws -> [DemoCategory] {
        projectedCategories(in: try planningSnapshot(month: month))
    }

    func projectedCategories(in plan: PlanningPeriodProjection.Snapshot) -> [DemoCategory] {
        return visibleCategories.map { category in
            var value = category
            if let row = plan.categories[category.id] {
                value.assigned = row.assignedMinor; value.activity = row.activityMinor; value.available = row.availableMinor
            }
            return value
        }
    }

    private func publishPlanning(_ plan: PlanningPeriodProjection.Snapshot) {
        for index in categories.indices {
            guard let value = plan.categories[categories[index].id] else { continue }
            categories[index].assigned = value.assignedMinor
            categories[index].activity = value.activityMinor
            categories[index].available = value.availableMinor
        }
        unassignedMinor = plan.allDateUnassignedMinor
    }

    func replaceAssignment(categoryID: String, month: String, assignedMinor: Int64) throws {
        guard !isRestricted else { throw DemoMutationError.restrictedCategory }
        guard let category = categories.first(where: { $0.id == categoryID }), !category.isHidden,
              !archivedGroups.contains(category.group) else { throw DemoMutationError.categoryNotFound }
        let selected = try planningSnapshot(month: month)
        guard let allocation = try selected.replacementAssignment(categoryID: categoryID, assignedMinor: assignedMinor) else { return }
        let current = try planningSnapshot(month: currentPlanningMonth, additionalAllocations: [allocation])
        recordAllocation(amount: allocation.postings[1].amountMinor, to: categoryID, occurredOn: month)
        publishPlanning(current)
    }

    private struct FinancialCheckpoint {
        let accounts: [DemoAccount]; let categories: [DemoCategory]; let transactions: [DemoTransaction]
        let reserve: [String: [String: Int64]]; let unassigned: Int64
    }
    private func checkpoint() -> FinancialCheckpoint {
        .init(accounts: accounts, categories: categories, transactions: transactions, reserve: reserveAttribution, unassigned: unassignedMinor)
    }
    private func restore(_ value: FinancialCheckpoint) {
        accounts = value.accounts; categories = value.categories; transactions = value.transactions
        reserveAttribution = value.reserve; unassignedMinor = value.unassigned
    }

    static func payeeID(_ name: String) -> String { "demo-payee-" + name.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static var seedPayees: [DemoPayee] {
        let system = Set(["transfer", "starting balance", "reconciliation adjustment"])
        return Array(Set(seedTransactions.map(\.payee))).filter { !system.contains($0.lowercased()) }.sorted().map { DemoPayee(id: payeeID($0), name: $0) }
    }

    @discardableResult
    func createAccount(name: String, type: String, isOnBudget: Bool, startingBalance: Int64 = 0) -> Bool {
        let cashOpening = isOnBudget && ["checking", "savings", "cash"].contains(type) ? startingBalance : 0
        guard let nextUnassigned = try? Money.sumMinorUnits([unassignedMinor, cashOpening]) else { return fail(.invalidAmount) }
        let id = UUID().uuidString
        accounts.append(.init(id: id, name: name, kind: DemoAccountKind(rawValue: type) ?? (isOnBudget ? .checking : .asset), balance: startingBalance, cleared: startingBalance, isOnBudget: isOnBudget))
        if startingBalance != 0 {
            transactions.insert(.init(id: UUID().uuidString, date: Date(), payee: "Starting Balance", memo: "Balance when account was added", accountID: id, categoryIDs: [], amount: startingBalance, member: persona, cleared: true), at: 0)
        }
        unassignedMinor = nextUnassigned
        errorMessage = nil
        return true
    }

    @discardableResult
    func updateAccount(id: String, name: String, type: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == id }), let kind = DemoAccountKind(rawValue: type) else {
            return false
        }
        accounts[index].name = name
        accounts[index].kind = kind
        return true
    }

    @discardableResult
    func move(amount: Int64, from sourceID: String, to destinationID: String,
              occurredOn: String = BudgetWorkspaceStore.dateString(Date()), note: String = "") -> Bool {
        guard amount > 0 else { return fail(.invalidAmount) }
        guard let source = categories.firstIndex(where: { $0.id == sourceID }),
              let destination = categories.firstIndex(where: { $0.id == destinationID }) else { return fail(.categoryNotFound) }
        if isRestricted && (categories[source].delegatedTo != persona || categories[destination].delegatedTo != persona) {
            return fail(.restrictedCategory)
        }
        guard source != destination, !categories[source].isHidden, !categories[destination].isHidden,
              !archivedGroups.contains(categories[source].group), !archivedGroups.contains(categories[destination].group) else { return fail(.categoryNotFound) }
        do {
            let day = try PlanningPeriodProjection.Day(occurredOn)
            let available = try planningSnapshot(month: day.month, through: occurredOn).categories[sourceID]?.availableMinor ?? 0
            guard available >= amount else { return fail(.insufficientFunds(available: available)) }
            let allocation = try PlanningPeriodProjection.Allocation(occurredOn: occurredOn, postings: [
                .init(categoryID: sourceID, amountMinor: -amount), .init(categoryID: destinationID, amountMinor: amount),
            ])
            let plan = try planningSnapshot(month: currentPlanningMonth, additionalAllocations: [allocation])
            recordAllocation(amount: amount, from: sourceID, to: destinationID, occurredOn: occurredOn,
                             kind: "category_transfer", note: note)
            publishPlanning(plan)
        } catch { return failMessage(error.localizedDescription) }
        errorMessage = nil
        return true
    }

    @discardableResult
    func approve(_ requestID: String, amount: Int64, sourceCategoryID: String = "buffer", note: String = "") -> Bool {
        guard !isRestricted else { return fail(.restrictedCategory) }
        guard let index = requests.firstIndex(where: { $0.id == requestID }), requests[index].status == "Pending" else {
            return failMessage("Request has already changed or is unavailable.")
        }
        guard amount > 0, amount <= requests[index].amount else { return fail(.invalidAmount) }
        guard let source = categories.firstIndex(where: { $0.id == sourceCategoryID }),
              let destination = categories.firstIndex(where: { $0.id == requests[index].categoryID }),
              source != destination,
              !categories[source].isHidden, !categories[destination].isHidden,
              !archivedGroups.contains(categories[source].group), !archivedGroups.contains(categories[destination].group) else {
            return fail(.categoryNotFound)
        }
        do {
            let day = BudgetWorkspaceStore.dateString(Date())
            let available = try planningSnapshot(month: currentPlanningMonth, through: day).categories[sourceCategoryID]?.availableMinor ?? 0
            guard available >= amount else { return fail(.insufficientFunds(available: available)) }
            let allocation = try PlanningPeriodProjection.Allocation(occurredOn: day, postings: [
                .init(categoryID: categories[source].id, amountMinor: -amount),
                .init(categoryID: categories[destination].id, amountMinor: amount),
            ])
            let plan = try planningSnapshot(month: currentPlanningMonth, additionalAllocations: [allocation])
            recordAllocation(amount: amount, from: categories[source].id, to: categories[destination].id,
                             occurredOn: day, kind: "request_approval", note: note.isEmpty ? requests[index].reason : note)
            publishPlanning(plan)
            requests[index].approvedAmount = amount
            requests[index].status = amount < requests[index].amount ? "Partially approved" : "Approved"
        } catch { return failMessage(error.localizedDescription) }
        errorMessage = nil
        return true
    }

    func addTransaction(payee: String, amount: Int64, accountID: String, categoryIDs: [String], memo: String, attachment: Bool) {
        guard Set(categoryIDs).count == categoryIDs.count else { _ = fail(.invalidAmount); return }
        let signed = amount > 0 ? -amount : amount
        let amounts = splitAmounts(total: signed, categoryIDs: categoryIDs)
        _ = recordCanonicalTransaction(.init(accountID: accountID, categoryID: categoryIDs.count == 1 ? categoryIDs[0] : nil, amountMinor: signed, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: payee, memo: memo, isCleared: false, splits: categoryIDs.count > 1 ? amounts.map { .init(categoryID: $0.key, amountMinor: $0.value, memo: "") } : [], flag: "New", tags: [], attachmentMetadata: attachment ? [["name": "receipt.jpg"]] : []))
    }

    func createTransaction(payee: String, signedAmount: Int64, date: Date = .demo(monthsAgo: 0, day: 30), accountID: String, categoryAmounts: [String: Int64], memo: String, cleared: Bool, flag: String? = nil, tags: [String] = [], attachmentName: String? = nil) {
        let categoryID = categoryAmounts.count == 1 ? categoryAmounts.keys.first : nil
        let splits = categoryAmounts.count > 1 ? categoryAmounts.map { TransactionSplitOperation(categoryID: $0.key, amountMinor: $0.value, memo: "") } : []
        _ = recordCanonicalTransaction(.init(accountID: accountID, categoryID: categoryID, amountMinor: signedAmount, occurredOn: BudgetWorkspaceStore.dateString(date), payeeName: payee, memo: memo, isCleared: cleared, splits: splits, flag: flag, tags: tags, attachmentMetadata: attachmentName.map { [["name": $0]] } ?? []))
    }

    func updateTransaction(
        id: String,
        payee: String,
        amount: Int64,
        accountID: String,
        categoryIDs: [String],
        memo: String,
        cleared: Bool,
        flag: String?
    ) -> Bool {
        guard amount > 0, Set(categoryIDs).count == categoryIDs.count else { return fail(.invalidAmount) }
        guard accounts.contains(where: { $0.id == accountID }) else { return fail(.accountNotFound) }
        let values = splitAmounts(total: amount, categoryIDs: categoryIDs)
        return updateCanonicalTransaction(id: id, operation: .init(
            accountID: accountID, categoryID: categoryIDs.count == 1 ? categoryIDs[0] : nil,
            amountMinor: -amount, occurredOn: transactions.first(where: { $0.id == id }).map { BudgetWorkspaceStore.dateString($0.date) } ?? BudgetWorkspaceStore.dateString(Date()),
            payeeName: payee, memo: memo, isCleared: cleared,
            splits: categoryIDs.count > 1 ? values.map { .init(categoryID: $0.key, amountMinor: -$0.value, memo: "") } : [],
            flag: flag, tags: [], attachmentMetadata: []
        ))
    }

    func updateTransactionSigned(id: String, payee: String, signedAmount: Int64, date: Date, accountID: String, categoryAmounts: [String: Int64], memo: String, cleared: Bool, flag: String?, tags: [String], attachmentName: String?) -> Bool {
        let categoryID = categoryAmounts.count == 1 ? categoryAmounts.keys.first : nil
        let splits = categoryAmounts.count > 1 ? categoryAmounts.map { TransactionSplitOperation(categoryID: $0.key, amountMinor: $0.value, memo: "") } : []
        return updateCanonicalTransaction(id: id, operation: .init(accountID: accountID, categoryID: categoryID, amountMinor: signedAmount, occurredOn: BudgetWorkspaceStore.dateString(date), payeeName: payee, memo: memo, isCleared: cleared, splits: splits, flag: flag, tags: tags, attachmentMetadata: attachmentName.map { [["name": $0]] } ?? []))
    }

    @discardableResult
    func deleteTransaction(id: String) -> Bool {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return fail(.transactionNotFound) }
        let transaction = transactions[index]
        guard !transaction.reconciled else { return fail(.invalidAmount) }
        let before = checkpoint()
        do {
            try reverseCanonicalTransaction(transaction)
            transactions.remove(at: index)
            publishPlanning(try planningSnapshot(month: currentPlanningMonth))
        }
        catch { restore(before); return failMessage(error.localizedDescription) }
        errorMessage = nil
        return true
    }

    @discardableResult
    func transfer(amount: Int64, from sourceID: String, to destinationID: String, memo: String, cleared: Bool, date: Date = .demo(monthsAgo: 0, day: 30)) -> Bool {
        guard amount > 0 else { return fail(.invalidAmount) }
        guard let source = accounts.firstIndex(where: { $0.id == sourceID }), let destination = accounts.firstIndex(where: { $0.id == destinationID }), source != destination else { return fail(.accountNotFound) }
        if accounts[destination].kind == .credit && accounts[destination].paymentReserved < amount {
            return fail(.insufficientFunds(available: accounts[destination].paymentReserved))
        }
        let transferID = UUID().uuidString
        do { accounts = try applyingTransferChanges([(source, destination, amount, cleared)]) }
        catch { return failMessage(error.localizedDescription) }
        transactions.insert(.init(id: "\(transferID)-in", date: date, payee: "Transfer", memo: memo, accountID: destinationID, categoryIDs: [], amount: amount, member: persona, cleared: cleared, transferID: transferID), at: 0)
        transactions.insert(.init(id: "\(transferID)-out", date: date, payee: "Transfer", memo: memo, accountID: sourceID, categoryIDs: [], amount: -amount, member: persona, cleared: cleared, transferID: transferID), at: 0)
        errorMessage = nil
        return true
    }

    @discardableResult
    func updateTransfer(id transferID: String, amount: Int64, from sourceID: String, to destinationID: String, memo: String, cleared: Bool, date: Date) -> Bool {
        guard amount > 0,
              let oldSourceLeg = transactions.first(where: { $0.transferID == transferID && $0.amount < 0 }),
              let oldDestinationLeg = transactions.first(where: { $0.transferID == transferID && $0.amount > 0 }),
              !oldSourceLeg.reconciled, !oldDestinationLeg.reconciled,
              let oldSource = accounts.firstIndex(where: { $0.id == oldSourceLeg.accountID }),
              let oldDestination = accounts.firstIndex(where: { $0.id == oldDestinationLeg.accountID }),
              let source = accounts.firstIndex(where: { $0.id == sourceID }),
              let destination = accounts.firstIndex(where: { $0.id == destinationID }), source != destination else { return fail(.invalidAmount) }
        guard let sourceLegIndex = transactions.firstIndex(where: { $0.id == oldSourceLeg.id }), let destinationLegIndex = transactions.firstIndex(where: { $0.id == oldDestinationLeg.id }) else { return fail(.transactionNotFound) }
        do {
            let updatedAccounts = try applyingTransferChanges([(oldSource, oldDestination, oldSourceLeg.amount, oldSourceLeg.cleared), (source, destination, amount, cleared)])
            if updatedAccounts[destination].kind == .credit && updatedAccounts[destination].paymentReserved < 0 {
                return fail(.insufficientFunds(available: try Money.sumMinorUnits([updatedAccounts[destination].paymentReserved, amount])))
            }
            accounts = updatedAccounts
        } catch { return failMessage(error.localizedDescription) }
        transactions[sourceLegIndex].accountID = sourceID; transactions[sourceLegIndex].amount = -amount; transactions[sourceLegIndex].memo = memo; transactions[sourceLegIndex].cleared = cleared; transactions[sourceLegIndex].date = date
        transactions[destinationLegIndex].accountID = destinationID; transactions[destinationLegIndex].amount = amount; transactions[destinationLegIndex].memo = memo; transactions[destinationLegIndex].cleared = cleared; transactions[destinationLegIndex].date = date
        errorMessage = nil; return true
    }

    @discardableResult
    func deleteTransfer(id transferID: String) -> Bool {
        guard let sourceLeg = transactions.first(where: { $0.transferID == transferID && $0.amount < 0 }),
              let destinationLeg = transactions.first(where: { $0.transferID == transferID && $0.amount > 0 }),
              !sourceLeg.reconciled, !destinationLeg.reconciled,
              let source = accounts.firstIndex(where: { $0.id == sourceLeg.accountID }),
              let destination = accounts.firstIndex(where: { $0.id == destinationLeg.accountID }) else { return fail(.transactionNotFound) }
        do { accounts = try applyingTransferChanges([(source, destination, sourceLeg.amount, sourceLeg.cleared)]) }
        catch { return failMessage(error.localizedDescription) }
        transactions.removeAll { $0.transferID == transferID }
        errorMessage = nil; return true
    }

    /// Stage all transfer legs together. Signed amounts reverse existing legs without publishing
    /// an intermediate account state; exact accumulation permits cancellation at edit boundaries.
    private func applyingTransferChanges(_ changes: [(source: Int, destination: Int, amount: Int64, cleared: Bool)]) throws -> [DemoAccount] {
        var balance: [Int: [Int64]] = [:], cleared: [Int: [Int64]] = [:], reserve: [Int: [Int64]] = [:]
        for change in changes {
            guard change.amount != .min else { throw MoneyError.arithmeticOverflow }
            balance[change.source, default: []].append(-change.amount)
            balance[change.destination, default: []].append(change.amount)
            if change.cleared {
                cleared[change.source, default: []].append(-change.amount)
                cleared[change.destination, default: []].append(change.amount)
            }
            if accounts[change.destination].kind == .credit { reserve[change.destination, default: []].append(-change.amount) }
            if accounts[change.source].kind == .credit { reserve[change.source, default: []].append(change.amount) }
        }
        var result = accounts
        for (index, changes) in balance { result[index].balance = try Money.sumMinorUnits([accounts[index].balance] + changes) }
        for (index, changes) in cleared { result[index].cleared = try Money.sumMinorUnits([accounts[index].cleared] + changes) }
        for (index, changes) in reserve { result[index].paymentReserved = try Money.sumMinorUnits([accounts[index].paymentReserved] + changes) }
        return result
    }

    @discardableResult
    func reconcile(accountID: String, statementBalance: Int64, throughDate: String = BudgetWorkspaceStore.dateString(Date()), createAdjustment: Bool = false, reason: String = "", expectedClearedBalance: Int64? = nil) -> Bool {
        guard !isRestricted else { return failMessage("You do not have permission to reconcile this account.") }
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return fail(.accountNotFound) }
        guard let cutoff = try? PlanningPeriodProjection.Day(throughDate),
              fixtureOpening.map({ cutoff >= $0.month }) ?? true else { return failMessage("Invalid reconciliation date.") }
        let eligible = transactions.filter { $0.accountID == accountID && $0.cleared && !$0.scheduled && BudgetWorkspaceStore.dateString($0.date) <= cutoff.iso }
        var cleared = fixtureAccountOpening[accountID] ?? 0
        for transaction in eligible {
            let result = cleared.addingReportingOverflow(transaction.amount)
            guard !result.overflow else { return fail(.invalidAmount) }
            cleared = result.partialValue
        }
        guard expectedClearedBalance == nil || expectedClearedBalance == cleared else { return failMessage("Account changed since reconciliation started.") }
        let result = statementBalance.subtractingReportingOverflow(cleared)
        guard !result.overflow else { return fail(.invalidAmount) }
        let difference = result.partialValue
        guard difference == 0 || createAdjustment else { return failMessage("Cleared balance does not match statement. Confirm an adjustment before continuing.") }
        if difference != 0 {
            guard recordCanonicalTransaction(.init(accountID: accountID, categoryID: nil, amountMinor: difference, occurredOn: cutoff.iso, payeeName: "Reconciliation adjustment", memo: reason.trimmingCharacters(in: .whitespacesAndNewlines), isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])) else { return false }
            transactions[0].reconciled = true
        }
        accounts[index].reconciledBalance = statementBalance
        let eligibleIDs = Set(eligible.map(\.id))
        for transactionIndex in transactions.indices where eligibleIDs.contains(transactions[transactionIndex].id) {
            transactions[transactionIndex].reconciled = true
        }
        errorMessage = nil
        return true
    }

    @discardableResult
    func createCategory(name: String, group: String = "Personal", initialAssignment: Int64 = 0) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetGroup = isRestricted ? "My Budget" : group
        guard !trimmedName.isEmpty, initialAssignment >= 0 else { return fail(.invalidAmount) }
        guard !categories.contains(where: { $0.group == targetGroup && normalizedCategoryName($0.name) == normalizedCategoryName(trimmedName) }) else {
            return failMessage("A category with this name already exists in the group.")
        }
        if isRestricted && initialAssignment > delegatedReadyToAssign {
            return fail(.exceedsDelegatedAuthority(available: delegatedReadyToAssign))
        }
        if !isRestricted && initialAssignment > unassignedMinor {
            return fail(.insufficientFunds(available: unassignedMinor))
        }
        categories.append(.init(
            id: UUID().uuidString,
            group: targetGroup,
            name: trimmedName,
            icon: "folder.fill",
            assigned: initialAssignment,
            activity: 0,
            available: initialAssignment,
            target: nil,
            delegatedTo: isRestricted ? persona : nil
        ))
        if !groupOrder.contains(targetGroup) { groupOrder.append(targetGroup) }
        if !isRestricted { unassignedMinor -= initialAssignment }
        if !isRestricted, let category = categories.last {
            recordAllocation(amount: initialAssignment, to: category.id, note: "Initial assignment")
        }
        errorMessage = nil
        return true
    }

    func issueAllowance(_ id: String) {
        guard let plan = allowances.first(where: { $0.id == id }), !plan.isPaused,
              let source = categories.firstIndex(where: { $0.id == "buffer" }),
              categories[source].available >= plan.amount else { return }
        categories[source].assigned -= plan.amount
        categories[source].available -= plan.amount
        for split in plan.splits {
            if let index = categories.firstIndex(where: { $0.name == split.0 }) {
                categories[index].assigned += split.1
                categories[index].available += split.1
                recordAllocation(amount: split.1, from: categories[source].id, to: categories[index].id,
                                 kind: "category_transfer", note: "Allowance")
            }
        }
    }

    @discardableResult
    func assign(amount: Int64, to categoryID: String,
                occurredOn: String = BudgetWorkspaceStore.dateString(Date())) -> Bool {
        guard amount > 0 else { return fail(.invalidAmount) }
        do {
            let month = try PlanningPeriodProjection.Day(occurredOn).month
            let selected = try planningSnapshot(month: month)
            guard let category = selected.categories[categoryID] else { return fail(.categoryNotFound) }
            let total = category.assignedMinor.addingReportingOverflow(amount)
            guard !total.overflow else { return fail(.invalidAmount) }
            try replaceAssignment(categoryID: categoryID, month: month, assignedMinor: total.partialValue)
            return true
        } catch { return failMessage(error.localizedDescription) }
    }

    func addGoal(name: String, amount: Int64, targetDate: String) {
        categories.append(.init(id: UUID().uuidString, group: "Goals", name: name, icon: "target", assigned: 0, activity: 0, available: 0, target: amount, targetDate: targetDate, pinned: true))
    }

    func transactions(in period: DemoReportPeriod, categoryID: String? = nil) -> [DemoTransaction] {
        visibleTransactions.filter { transaction in
            period.contains(transaction.date) && (categoryID == nil || transaction.categoryIDs.contains(categoryID!))
        }
    }

    func spendingByCategory(in period: DemoReportPeriod) -> [(DemoCategory, Int64, [DemoTransaction])] {
        visibleCategories.compactMap { category in
            let contributing = transactions(in: period, categoryID: category.id).filter { $0.transferID == nil && $0.amount != 0 }
            let total = contributing.reduce(Int64(0)) { partial, transaction in
                partial - (canonicalCategoryAmounts(for: transaction)[category.id] ?? 0)
            }
            return total <= 0 ? nil : (category, total, contributing)
        }.sorted { $0.1 > $1.1 }
    }

    @discardableResult
    func recordCanonicalTransaction(_ operation: RecordTransactionOperation, id: String = UUID().uuidString) -> Bool {
        guard operation.amountMinor != 0,
              let account = accounts.first(where: { $0.id == operation.accountID }) else { return fail(.invalidAmount) }
        let occurredOn = BudgetWorkspaceStore.parseDate(operation.occurredOn)
        guard Calendar.current.startOfDay(for: occurredOn) <= Calendar.current.startOfDay(for: Date()) else { return fail(.invalidAmount) }
        guard Set(operation.splits.map(\.categoryID)).count == operation.splits.count else { return fail(.invalidAmount) }
        let amounts = operation.categoryID.map { [$0: operation.amountMinor] }
            ?? Dictionary(uniqueKeysWithValues: operation.splits.map { ($0.categoryID, $0.amountMinor) })
        guard (try? Money.sumMinorUnits(amounts.values)) == (amounts.isEmpty ? 0 : operation.amountMinor),
              amounts.keys.allSatisfy({ id in categories.contains { $0.id == id } }),
              account.isOnBudget || amounts.isEmpty else { return fail(.invalidAmount) }
        let transaction = DemoTransaction(
            id: id, date: occurredOn, payee: operation.payeeName, memo: operation.memo,
            accountID: operation.accountID, categoryIDs: operation.categoryID.map { [$0] } ?? operation.splits.map(\.categoryID), categoryAmounts: amounts,
            amount: operation.amountMinor, member: persona, cleared: operation.isCleared, flag: operation.flag,
            attachmentName: operation.attachmentMetadata.first?["name"], tags: operation.tags,
            financialClassification: operation.financialClassification,
            splitFinancialClassifications: Dictionary(uniqueKeysWithValues: operation.splits.compactMap { split in
                split.financialClassification.map { (split.categoryID, $0) }
            })
        )
        let before = checkpoint()
        do {
            try applyCanonicalTransaction(transaction)
            transactions.insert(transaction, at: 0)
            publishPlanning(try planningSnapshot(month: currentPlanningMonth))
        } catch { restore(before); return failMessage(error.localizedDescription) }
        errorMessage = nil
        return true
    }

    @discardableResult
    func updateCanonicalTransaction(id: String, operation: RecordTransactionOperation) -> Bool {
        guard let index = transactions.firstIndex(where: { $0.id == id }), !transactions[index].reconciled else { return fail(.transactionNotFound) }
        let old = transactions[index]
        let before = checkpoint()
        do { try reverseCanonicalTransaction(old) }
        catch { restore(before); return failMessage(error.localizedDescription) }
        transactions.remove(at: index)
        guard recordCanonicalTransaction(operation, id: id) else {
            restore(before)
            return false
        }
        return true
    }

    private func applyCanonicalTransaction(_ transaction: DemoTransaction) throws {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == transaction.accountID }) else { return }
        let amounts = canonicalCategoryAmounts(for: transaction)
        var reserve: [String: Int64] = [:]
        if accounts[accountIndex].kind == .credit {
            let day = BudgetWorkspaceStore.dateString(transaction.date)
            let datedPlan = try planningSnapshot(month: String(day.prefix(7)) + "-01", through: day)
            var datedReserve: Int64 = 0
            for item in transactions where item.accountID == transaction.accountID && item.date <= transaction.date {
                let amount = try (item.transferID != nil ? subtract(0, item.amount) : Money.sumMinorUnits((reserveAttribution[item.id] ?? [:]).values))
                let sum = datedReserve.addingReportingOverflow(amount)
                guard !sum.overflow else { throw MoneyError.arithmeticOverflow }
                datedReserve = sum.partialValue
            }
            var remainingPaymentMoney = max(datedReserve, 0)
            // Preserve canonical split order when several refund rows compete for the same reserve.
            for categoryID in transaction.categoryIDs {
                guard let amount = amounts[categoryID] else { continue }
                guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }) else { continue }
                if amount < 0 {
                    let availableBefore = datedPlan.categories[categories[categoryIndex].id]?.availableMinor ?? 0
                    reserve[categoryID] = Int64(min(amount.magnitude, UInt64(max(availableBefore, 0))))
                } else if amount > 0 {
                    // Match the server's net, card/category/date-scoped attribution. Earlier refund
                    // releases reduce that attribution; another card's purchases cannot fund it.
                    let attributed = try Money.sumMinorUnits(transactions.lazy.filter {
                        $0.accountID == transaction.accountID && $0.date <= transaction.date
                    }.map { self.reserveAttribution[$0.id]?[categoryID] ?? 0 })
                    let released = min(amount, max(attributed, 0), remainingPaymentMoney)
                    reserve[categoryID] = -released
                    remainingPaymentMoney -= released
                }
            }
        }
        accounts[accountIndex].balance = try Money.sumMinorUnits([accounts[accountIndex].balance, transaction.amount])
        if transaction.cleared { accounts[accountIndex].cleared = try Money.sumMinorUnits([accounts[accountIndex].cleared, transaction.amount]) }
        if amounts.isEmpty {
            if accounts[accountIndex].isOnBudget && [.checking, .savings, .cash].contains(accounts[accountIndex].kind) && !isRestricted {
                unassignedMinor = try Money.sumMinorUnits([unassignedMinor, transaction.amount])
            }
        } else {
            for (categoryID, amount) in amounts where categories.contains(where: { $0.id == categoryID }) {
                let categoryIndex = categories.firstIndex(where: { $0.id == categoryID })!
                categories[categoryIndex].activity = try Money.sumMinorUnits([categories[categoryIndex].activity, amount])
                categories[categoryIndex].available = try Money.sumMinorUnits([categories[categoryIndex].available, amount])
            }
        }
        if !reserve.isEmpty {
            let reserved = try Money.sumMinorUnits(reserve.values)
            accounts[accountIndex].paymentReserved = try Money.sumMinorUnits([accounts[accountIndex].paymentReserved, reserved])
            if transaction.amount < 0 {
                accounts[accountIndex].fundedSpending = try Money.sumMinorUnits([accounts[accountIndex].fundedSpending, reserved])
                accounts[accountIndex].unfundedSpending = try Money.sumMinorUnits([accounts[accountIndex].unfundedSpending, subtract(subtract(0, transaction.amount), reserved)])
            }
            reserveAttribution[transaction.id] = reserve
        }
    }

    private func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else { throw MoneyError.arithmeticOverflow }
        return result.partialValue
    }

    private func reverseCanonicalTransaction(_ transaction: DemoTransaction) throws {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == transaction.accountID }) else { return }
        accounts[accountIndex].balance = try subtract(accounts[accountIndex].balance, transaction.amount)
        if transaction.cleared { accounts[accountIndex].cleared = try subtract(accounts[accountIndex].cleared, transaction.amount) }
        let amounts = canonicalCategoryAmounts(for: transaction)
        if amounts.isEmpty {
            if accounts[accountIndex].isOnBudget && [.checking, .savings, .cash].contains(accounts[accountIndex].kind) && !isRestricted {
                unassignedMinor = try subtract(unassignedMinor, transaction.amount)
            }
        } else {
            for (categoryID, amount) in amounts where categories.contains(where: { $0.id == categoryID }) {
                let categoryIndex = categories.firstIndex(where: { $0.id == categoryID })!
                categories[categoryIndex].activity = try subtract(categories[categoryIndex].activity, amount)
                categories[categoryIndex].available = try subtract(categories[categoryIndex].available, amount)
            }
        }
        let reserve = try Money.sumMinorUnits((reserveAttribution.removeValue(forKey: transaction.id) ?? [:]).values)
        accounts[accountIndex].paymentReserved = try subtract(accounts[accountIndex].paymentReserved, reserve)
        if accounts[accountIndex].kind == .credit && transaction.amount < 0 {
            accounts[accountIndex].fundedSpending = try subtract(accounts[accountIndex].fundedSpending, reserve)
            accounts[accountIndex].unfundedSpending = try subtract(accounts[accountIndex].unfundedSpending, subtract(subtract(0, transaction.amount), reserve))
        }
    }

    func canonicalCategoryAmounts(for transaction: DemoTransaction) -> [String: Int64] {
        if !transaction.categoryAmounts.isEmpty { return transaction.categoryAmounts }
        guard !transaction.categoryIDs.isEmpty else { return [:] }
        return splitAmounts(total: transaction.amount, categoryIDs: transaction.categoryIDs)
    }

    /// Immutable observation of reserve changes recorded when the transaction posted.
    /// Refunds/reversals retain their signed release; edits/deletes replace/remove attribution.
    func recordedReserveAmounts(transactionID: String) -> [String: Int64] {
        reserveAttribution[transactionID] ?? [:]
    }

    private func splitAmounts(total: Int64, categoryIDs: [String]) -> [String: Int64] {
        let ids = Set(categoryIDs).sorted()
        guard !ids.isEmpty else { return [:] }
        let base = total / Int64(ids.count)
        var remainder = total % Int64(ids.count)
        var result: [String: Int64] = [:]
        for id in ids {
            let extra: Int64 = remainder > 0 ? 1 : (remainder < 0 ? -1 : 0)
            result[id] = base + extra
            remainder -= extra
        }
        return result
    }

    private func fail(_ error: DemoMutationError) -> Bool {
        errorMessage = error.localizedDescription
        return false
    }

    private func failMessage(_ message: String) -> Bool {
        errorMessage = message
        return false
    }

    // Explicit account opening observations at 2025-10-01, not current display balances.
    static let seedAccounts: [DemoAccount] = [
        .init(id: "checking", name: "Household Checking", kind: .checking, balance: 2_000_000, cleared: 2_000_000),
        .init(id: "savings", name: "High-Yield Savings", kind: .savings, balance: 2_000_000, cleared: 2_000_000),
        .init(id: "cash", name: "Wallet Cash", kind: .cash, balance: 18000, cleared: 18000),
        .init(id: "visa", name: "Everyday Visa", kind: .credit, balance: -20_000, cleared: -20_000, apr: 20.49, minimumPayment: 4500, dueText: "Due Sep 18"),
        .init(id: "mastercard", name: "Travel Mastercard", kind: .credit, balance: -10_000, cleared: -10_000, dueText: "Due Sep 24"),
        .init(id: "auto", name: "Auto Loan", kind: .loan, balance: -1875000, cleared: -1875000, isOnBudget: false, apr: 6.25, minimumPayment: 41200, dueText: "Due Oct 1"),
        .init(id: "mortgage", name: "Home Mortgage", kind: .mortgage, balance: -23840000, cleared: -23840000, isOnBudget: false, apr: 3.75, minimumPayment: 184500, dueText: "Due Oct 1"),
        .init(id: "home", name: "Home Value", kind: .asset, balance: 39200000, cleared: 39200000, isOnBudget: false)
    ]

    // Metadata and September assignment intent only. Activity/Available are projected from facts.
    static let seedCategories: [DemoCategory] = [
        .init(id:"mortgage",group:"Housing",name:"Mortgage",icon:"house.fill",assigned:184500,activity:0,available:0,target:184500,pinned:true),
        .init(id:"electric",group:"Housing",name:"Electric",icon:"bolt.fill",assigned:16500,activity:0,available:0,target:16500),
        .init(id:"water",group:"Housing",name:"Water",icon:"drop.fill",assigned:8500,activity:0,available:0,target:8500),
        .init(id:"internet",group:"Housing",name:"Internet",icon:"wifi",assigned:7900,activity:0,available:0,target:7900),
        .init(id:"groceries",group:"Food",name:"Groceries",icon:"cart.fill",assigned:72000,activity:0,available:0,target:72000,pinned:true),
        .init(id:"dining",group:"Food",name:"Dining Out",icon:"fork.knife",assigned:22000,activity:0,available:0,target:22000),
        .init(id:"fuel",group:"Transportation",name:"Fuel",icon:"fuelpump.fill",assigned:28000,activity:0,available:0,target:30000),
        .init(id:"maintenance",group:"Transportation",name:"Car Maintenance",icon:"wrench.and.screwdriver.fill",assigned:15000,activity:0,available:0,target:120000,targetDate:"2026-12-01"),
        .init(id:"medical",group:"True Expenses",name:"Medical",icon:"cross.case.fill",assigned:10000,activity:0,available:0,target:50000),
        .init(id:"repair",group:"True Expenses",name:"Home Repair",icon:"hammer.fill",assigned:25000,activity:0,available:0,target:300000),
        .init(id:"christmas",group:"True Expenses",name:"Christmas",icon:"gift.fill",assigned:35000,activity:0,available:0,target:300000,targetDate:"2026-12-01"),
        .init(id:"subscriptions",group:"True Expenses",name:"Annual Subscriptions",icon:"calendar.badge.clock",assigned:12000,activity:0,available:0,target:120000,targetDate:"2027-01-01"),
        .init(id:"buffer",group:"True Expenses",name:"General Buffer",icon:"tray.full.fill",assigned:35000,activity:0,available:0,target:35000),
        .init(id:"emergency",group:"Goals",name:"Emergency Fund",icon:"shield.fill",assigned:50000,activity:0,available:0,target:1500000,pinned:true),
        .init(id:"vacation",group:"Goals",name:"Vacation",icon:"airplane",assigned:40000,activity:0,available:0,target:600000,targetDate:"2027-06-01"),
        .init(id:"cnc",group:"Goals",name:"CNC Machine",icon:"gearshape.2.fill",assigned:25000,activity:0,available:0,target:200000,targetDate:"2027-06-01",pinned:true),
        .init(id:"newcar",group:"Goals",name:"New Car",icon:"car.side.fill",assigned:30000,activity:0,available:0,target:2500000,targetDate:"2029-09-01"),
        .init(id:"rey",group:"Personal",name:"Rey Spending",icon:"person.fill",assigned:20000,activity:0,available:0,target:20000),
        .init(id:"partner",group:"Personal",name:"Jordan Spending",icon:"person.fill",assigned:20000,activity:0,available:0,target:20000),
        .init(id:"alexallow",group:"Kids",name:"Alex Allowance",icon:"gamecontroller.fill",assigned:4800,activity:0,available:0,target:4800,delegatedTo:.alex),
        .init(id:"alexsave",group:"Kids",name:"Alex Savings",icon:"banknote.fill",assigned:2000,activity:0,available:0,target:50000,targetDate:"2027-03-01",delegatedTo:.alex),
        .init(id:"alexgive",group:"Kids",name:"Giving",icon:"heart.fill",assigned:0,activity:0,available:0,target:nil,delegatedTo:.alex),
        .init(id:"miaallow",group:"Kids",name:"Mia Allowance",icon:"paintpalette.fill",assigned:3200,activity:0,available:0,target:3200,delegatedTo:.mia),
        .init(id:"miabike",group:"Kids",name:"Mia Bike Goal",icon:"bicycle",assigned:1200,activity:0,available:0,target:50000,targetDate:"2027-05-01",delegatedTo:.mia)
    ]

    static var seedTransactions: [DemoTransaction] {
        var items: [DemoTransaction] = [
            .init(id:"t1",date:.demo(monthsAgo:0,day:3),payee:"Fresh Market",memo:"Weekly groceries",accountID:"visa",categoryIDs:["groceries"],amount:-12500,member:.rey,cleared:false,flag:"Groceries",attachmentName:"receipt-placeholder.png"),
            .init(id:"t2",date:.demo(monthsAgo:0,day:2),payee:"Payroll",memo:"September paycheck",accountID:"checking",categoryIDs:[],amount:375000,member:.rey,cleared:true),
            .init(id:"t3",date:.demo(monthsAgo:0,day:8),payee:"Corner Bistro",memo:"Family dinner",accountID:"mastercard",categoryIDs:["dining"],amount:-26840,member:.partner,cleared:true),
            .init(id:"t4",date:.demo(monthsAgo:0,day:11),payee:"Home Center",memo:"Paint and repair supplies",accountID:"checking",categoryIDs:["repair","maintenance"],amount:-12640,member:.rey,cleared:true,flag:"Split"),
            .init(id:"t5",date:.demo(monthsAgo:0,day:15),payee:"Auto Loan Payment",memo:"Principal $315 · Interest $97",accountID:"checking",categoryIDs:["maintenance"],amount:-41200,member:.rey,cleared:true),
            .init(id:"t6",date:.demo(monthsAgo:0,day:12),payee:"Weekly Allowance",memo:"Posted allowance spending",accountID:"checking",categoryIDs:["alexallow","alexsave"],amount:-2000,member:.alex,cleared:true),
            .init(id:"t7",date:.demo(monthsAgo:0,day:14),payee:"Card issuer",memo:"Posted finance charge",accountID:"visa",categoryIDs:["maintenance"],amount:-3200,member:.rey,cleared:true,financialClassification:"interest_charge")
        ]
        let merchants = ["Fresh Market","Fuel Station","Electric Co.","Neighborhood Cafe","Pharmacy","Internet Service"]
        let category = ["groceries","fuel","electric","dining","medical","internet"]
        for month in 1...11 {
            for index in 0..<6 {
                let amount = Int64(3200 + month * 173 + index * 947)
                items.append(.init(id:"h\(month)-\(index)",date:.demo(monthsAgo:month,day:4 + index * 3),payee:merchants[index],memo:"Historical demo activity",accountID:index % 3 == 0 ? "visa" : "checking",categoryIDs:[category[index]],amount:-amount,member:index % 2 == 0 ? .rey : .partner,cleared:true))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    static let seedRequests: [DemoRequest] = [
        .init(id:"request-game",member:.alex,amount:3500,categoryID:"alexallow",reason:"New game",status:"Pending",date:.demo(monthsAgo:0,day:4)),
        .init(id:"request-art",member:.mia,amount:1800,approvedAmount:1800,categoryID:"miaallow",reason:"Art supplies",status:"Approved",date:.demo(monthsAgo:1,day:15)),
        .init(id:"request-concert",member:.alex,amount:6500,categoryID:"alexallow",reason:"Concert ticket",status:"Declined",date:.demo(monthsAgo:2,day:8))
    ]

    static let seedAllowances: [DemoAllowance] = [
        .init(id:"alex-weekly",member:.alex,amount:2000,frequency:"Every Friday",nextDate:"Friday · Sep 11",source:"General Buffer",splits:[("Alex Allowance",1200),("Alex Savings",500),("Giving",300)],rollover:true),
        .init(id:"mia-weekly",member:.mia,amount:1200,frequency:"Every Friday",nextDate:"Friday · Sep 11",source:"General Buffer",splits:[("Mia Allowance",800),("Mia Bike Goal",400)],rollover:true)
    ]

    static let seedSchedules: [DemoSchedule] = [
        .init(id: "schedule-utility", accountID: "checking", categoryID: "electric", name: "Electric utility", amount: -16_500, nextDate: "2026-09-04", recurrenceUnit: "months", memo: "Monthly utility"),
        .init(id: "schedule-payroll", accountID: "checking", name: "Payroll", amount: 375_000, nextDate: "2026-09-11", recurrenceUnit: "weeks", intervalCount: 2, memo: "Forecast income only"),
        .init(id: "schedule-transfer", accountID: "checking", destinationAccountID: "savings", name: "Savings transfer", amount: 25_000, nextDate: "2026-09-05", recurrenceUnit: "months"),
        .init(id: "schedule-card", accountID: "visa", categoryID: "groceries", name: "Grocery delivery", amount: -12_500, nextDate: "2026-09-05", recurrenceUnit: "weeks"),
        .init(id: "schedule-inactive", accountID: "checking", categoryID: "internet", name: "Old internet plan", amount: -7_900, nextDate: "2026-09-20", recurrenceUnit: "months", isActive: false)
    ]
}
