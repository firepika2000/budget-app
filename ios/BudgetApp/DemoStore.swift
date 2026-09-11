import Foundation
import SwiftUI

@MainActor
final class DemoStore: ObservableObject {
    @Published var persona: DemoPersona = .rey
    @Published var hideAmounts = false
    @Published var accounts: [DemoAccount]
    @Published var categories: [DemoCategory]
    @Published var transactions: [DemoTransaction]
    @Published var schedules: [DemoSchedule]
    @Published var requests: [DemoRequest]
    @Published var allowances: [DemoAllowance]
    @Published var groupOrder: [String]
    @Published var archivedGroups = Set<String>()
    @Published var selectedMonth = "September 2026"
    @Published private(set) var unassignedMinor: Int64 = 320000
    @Published var errorMessage: String?
    private var reserveAttribution: [String: [String: Int64]] = [:]

    let incomeHistory: [Int64] = [725000, 738000, 725000, 760000, 742000, 750000]
    let spendingHistory: [Int64] = [594000, 621000, 609000, 642000, 598000, 634000]
    let netWorthHistory: [Int64] = [12840000, 12976000, 13112000, 13200000, 13358000, 13593000]

    init() {
        accounts = Self.seedAccounts
        categories = Self.seedCategories
        transactions = Self.seedTransactions
        schedules = Self.seedSchedules
        requests = Self.seedRequests
        allowances = Self.seedAllowances
        groupOrder = Array(Set(Self.seedCategories.map(\.group))).sorted()
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
        let allocationDifference = unassignedMinor + categories.reduce(Int64(0)) { $0 + $1.assigned } - budgetCash
        return FinancialObservation(accounts: accountValues, categories: categoryValues, cards: cards,
                                    unassignedMinor: unassignedMinor, totalBudgetCashMinor: budgetCash,
                                    netWorthMinor: netWorth, transactionCount: transactions.count,
                                    allocationPostingsSumMinor: allocationDifference)
    }

    func money(_ amount: Int64) -> String { hideAmounts ? "••••" : amount.demoCurrency }

    func reset() {
        persona = .rey
        hideAmounts = false
        accounts = Self.seedAccounts
        categories = Self.seedCategories
        transactions = Self.seedTransactions
        schedules = Self.seedSchedules
        requests = Self.seedRequests
        allowances = Self.seedAllowances
        groupOrder = Array(Set(Self.seedCategories.map(\.group))).sorted()
        archivedGroups = []
        unassignedMinor = 320000
        reserveAttribution = [:]
    }

    func setUnassigned(_ value: Int64) { unassignedMinor = value }

    func createAccount(name: String, type: String, isOnBudget: Bool, startingBalance: Int64 = 0) {
        let id = UUID().uuidString
        accounts.append(.init(id: id, name: name, kind: DemoAccountKind(rawValue: type) ?? (isOnBudget ? .checking : .asset), balance: startingBalance, cleared: startingBalance, isOnBudget: isOnBudget))
        if startingBalance != 0 {
            transactions.insert(.init(id: UUID().uuidString, date: Date(), payee: "Starting Balance", memo: "Balance when account was added", accountID: id, categoryIDs: [], amount: startingBalance, member: persona, cleared: true), at: 0)
            if isOnBudget && ["checking", "savings", "cash"].contains(type) { unassignedMinor += startingBalance }
        }
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
    func move(amount: Int64, from sourceID: String, to destinationID: String) -> Bool {
        guard amount > 0 else { return fail(.invalidAmount) }
        guard let source = categories.firstIndex(where: { $0.id == sourceID }),
              let destination = categories.firstIndex(where: { $0.id == destinationID }) else { return fail(.categoryNotFound) }
        if isRestricted && (categories[source].delegatedTo != persona || categories[destination].delegatedTo != persona) {
            return fail(.restrictedCategory)
        }
        guard categories[source].available >= amount else { return fail(.insufficientFunds(available: categories[source].available)) }
        categories[source].assigned -= amount
        categories[source].available -= amount
        categories[destination].assigned += amount
        categories[destination].available += amount
        errorMessage = nil
        return true
    }

    func approve(_ requestID: String, amount: Int64) {
        guard let index = requests.firstIndex(where: { $0.id == requestID }),
              let source = categories.firstIndex(where: { $0.id == "buffer" }),
              categories[source].available >= amount else { return }
        requests[index].approvedAmount = amount
        requests[index].status = amount < requests[index].amount ? "Partially approved" : "Approved"
        categories[source].assigned -= amount
        categories[source].available -= amount
        if let category = categories.firstIndex(where: { $0.id == requests[index].categoryID }) {
            categories[category].assigned += amount
            categories[category].available += amount
        }
    }

    func addTransaction(payee: String, amount: Int64, accountID: String, categoryIDs: [String], memo: String, attachment: Bool) {
        let signed = -abs(amount)
        let amounts = Dictionary(uniqueKeysWithValues: splitAmounts(total: abs(amount), categoryIDs: categoryIDs).map { ($0.key, -$0.value) })
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
        guard amount > 0 else { return fail(.invalidAmount) }
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
        reverseCanonicalTransaction(transaction)
        transactions.remove(at: index)
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
        accounts[source].balance -= amount; accounts[destination].balance += amount
        if cleared { accounts[source].cleared -= amount; accounts[destination].cleared += amount }
        if accounts[destination].kind == .credit { accounts[destination].paymentReserved -= amount }
        if accounts[source].kind == .credit { accounts[source].paymentReserved += amount }
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
        let oldAmount = -oldSourceLeg.amount
        var updatedAccounts = accounts
        updatedAccounts[oldSource].balance += oldAmount; updatedAccounts[oldDestination].balance -= oldAmount
        if oldSourceLeg.cleared { updatedAccounts[oldSource].cleared += oldAmount; updatedAccounts[oldDestination].cleared -= oldAmount }
        if updatedAccounts[oldDestination].kind == .credit { updatedAccounts[oldDestination].paymentReserved += oldAmount }
        if updatedAccounts[oldSource].kind == .credit { updatedAccounts[oldSource].paymentReserved -= oldAmount }
        if updatedAccounts[destination].kind == .credit && updatedAccounts[destination].paymentReserved < amount { return fail(.insufficientFunds(available: updatedAccounts[destination].paymentReserved)) }
        updatedAccounts[source].balance -= amount; updatedAccounts[destination].balance += amount
        if cleared { updatedAccounts[source].cleared -= amount; updatedAccounts[destination].cleared += amount }
        if updatedAccounts[destination].kind == .credit { updatedAccounts[destination].paymentReserved -= amount }
        if updatedAccounts[source].kind == .credit { updatedAccounts[source].paymentReserved += amount }
        accounts = updatedAccounts
        guard let sourceLegIndex = transactions.firstIndex(where: { $0.id == oldSourceLeg.id }), let destinationLegIndex = transactions.firstIndex(where: { $0.id == oldDestinationLeg.id }) else { return fail(.transactionNotFound) }
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
        let amount = -sourceLeg.amount
        accounts[source].balance += amount; accounts[destination].balance -= amount
        if sourceLeg.cleared { accounts[source].cleared += amount; accounts[destination].cleared -= amount }
        if accounts[destination].kind == .credit { accounts[destination].paymentReserved += amount }
        if accounts[source].kind == .credit { accounts[source].paymentReserved -= amount }
        transactions.removeAll { $0.transferID == transferID }
        errorMessage = nil; return true
    }

    @discardableResult
    func reconcile(accountID: String, statementBalance: Int64) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return fail(.accountNotFound) }
        let difference = statementBalance - accounts[index].cleared
        if difference != 0 {
            guard recordCanonicalTransaction(.init(accountID: accountID, categoryID: nil, amountMinor: difference, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: "Reconciliation adjustment", memo: "Confirmed statement balance", isCleared: true, splits: [], flag: "Reconciled", tags: [], attachmentMetadata: [])) else { return false }
            transactions[0].reconciled = true
        }
        accounts[index].cleared = statementBalance
        for transactionIndex in transactions.indices where transactions[transactionIndex].accountID == accountID && transactions[transactionIndex].cleared {
            transactions[transactionIndex].reconciled = true
        }
        errorMessage = nil
        return true
    }

    @discardableResult
    func createCategory(name: String, group: String = "Personal", initialAssignment: Int64 = 0) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, initialAssignment >= 0 else { return fail(.invalidAmount) }
        if isRestricted && initialAssignment > delegatedReadyToAssign {
            return fail(.exceedsDelegatedAuthority(available: delegatedReadyToAssign))
        }
        if !isRestricted && initialAssignment > unassignedMinor {
            return fail(.insufficientFunds(available: unassignedMinor))
        }
        categories.append(.init(
            id: UUID().uuidString,
            group: isRestricted ? "My Budget" : group,
            name: name,
            icon: "folder.fill",
            assigned: initialAssignment,
            activity: 0,
            available: initialAssignment,
            target: nil,
            delegatedTo: isRestricted ? persona : nil
        ))
        if !isRestricted { unassignedMinor -= initialAssignment }
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
            }
        }
    }

    func assign(amount: Int64, to categoryID: String) {
        guard amount > 0, amount <= unassignedMinor,
              let destination = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        unassignedMinor -= amount
        categories[destination].assigned += amount
        categories[destination].available += amount
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
        let amounts = operation.categoryID.map { [$0: operation.amountMinor] }
            ?? Dictionary(uniqueKeysWithValues: operation.splits.map { ($0.categoryID, $0.amountMinor) })
        guard amounts.values.reduce(0, +) == (amounts.isEmpty ? 0 : operation.amountMinor),
              amounts.keys.allSatisfy({ id in categories.contains { $0.id == id } }),
              account.isOnBudget || amounts.isEmpty else { return fail(.invalidAmount) }
        let transaction = DemoTransaction(
            id: id, date: occurredOn, payee: operation.payeeName, memo: operation.memo,
            accountID: operation.accountID, categoryIDs: Array(amounts.keys).sorted(), categoryAmounts: amounts,
            amount: operation.amountMinor, member: persona, cleared: operation.isCleared, flag: operation.flag,
            attachmentName: operation.attachmentMetadata.first?["name"], tags: operation.tags
        )
        applyCanonicalTransaction(transaction)
        transactions.insert(transaction, at: 0)
        errorMessage = nil
        return true
    }

    @discardableResult
    func updateCanonicalTransaction(id: String, operation: RecordTransactionOperation) -> Bool {
        guard let index = transactions.firstIndex(where: { $0.id == id }), !transactions[index].reconciled else { return fail(.transactionNotFound) }
        let old = transactions[index]
        reverseCanonicalTransaction(old)
        transactions.remove(at: index)
        guard recordCanonicalTransaction(operation, id: id) else {
            applyCanonicalTransaction(old)
            transactions.insert(old, at: index)
            return false
        }
        return true
    }

    private func applyCanonicalTransaction(_ transaction: DemoTransaction) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == transaction.accountID }) else { return }
        let amounts = canonicalCategoryAmounts(for: transaction)
        var reserve: [String: Int64] = [:]
        if accounts[accountIndex].kind == .credit {
            for (categoryID, amount) in amounts {
                guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }) else { continue }
                if amount < 0 {
                    let availableBefore = categories[categoryIndex].available
                    reserve[categoryID] = min(-amount, max(availableBefore, 0))
                } else if amount > 0 {
                    let attributed = reserveAttribution.values.reduce(Int64(0)) { $0 + max($1[categoryID] ?? 0, 0) }
                    reserve[categoryID] = -min(amount, attributed, max(accounts[accountIndex].paymentReserved, 0))
                }
            }
        }
        accounts[accountIndex].balance += transaction.amount
        if transaction.cleared { accounts[accountIndex].cleared += transaction.amount }
        if amounts.isEmpty {
            if accounts[accountIndex].isOnBudget && [.checking, .savings, .cash].contains(accounts[accountIndex].kind) && !isRestricted {
                unassignedMinor += transaction.amount
            }
        } else {
            for (categoryID, amount) in amounts where categories.contains(where: { $0.id == categoryID }) {
                let categoryIndex = categories.firstIndex(where: { $0.id == categoryID })!
                categories[categoryIndex].activity += amount
                categories[categoryIndex].available += amount
            }
        }
        if !reserve.isEmpty {
            let reserved = reserve.values.reduce(0, +)
            accounts[accountIndex].paymentReserved += reserved
            if transaction.amount < 0 {
                accounts[accountIndex].fundedSpending += reserved
                accounts[accountIndex].unfundedSpending += -transaction.amount - reserved
            }
            reserveAttribution[transaction.id] = reserve
        }
    }

    private func reverseCanonicalTransaction(_ transaction: DemoTransaction) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == transaction.accountID }) else { return }
        accounts[accountIndex].balance -= transaction.amount
        if transaction.cleared { accounts[accountIndex].cleared -= transaction.amount }
        let amounts = canonicalCategoryAmounts(for: transaction)
        if amounts.isEmpty {
            if accounts[accountIndex].isOnBudget && [.checking, .savings, .cash].contains(accounts[accountIndex].kind) && !isRestricted {
                unassignedMinor -= transaction.amount
            }
        } else {
            for (categoryID, amount) in amounts where categories.contains(where: { $0.id == categoryID }) {
                let categoryIndex = categories.firstIndex(where: { $0.id == categoryID })!
                categories[categoryIndex].activity -= amount
                categories[categoryIndex].available -= amount
            }
        }
        let reserve = reserveAttribution.removeValue(forKey: transaction.id)?.values.reduce(0, +) ?? 0
        accounts[accountIndex].paymentReserved -= reserve
        if transaction.amount < 0 {
            accounts[accountIndex].fundedSpending -= reserve
            accounts[accountIndex].unfundedSpending -= -transaction.amount - reserve
        }
    }

    func canonicalCategoryAmounts(for transaction: DemoTransaction) -> [String: Int64] {
        if !transaction.categoryAmounts.isEmpty { return transaction.categoryAmounts }
        guard !transaction.categoryIDs.isEmpty else { return [:] }
        let magnitude = splitAmounts(total: abs(transaction.amount), categoryIDs: transaction.categoryIDs)
        return magnitude.mapValues { transaction.amount < 0 ? -$0 : $0 }
    }

    private func splitAmounts(total: Int64, categoryIDs: [String]) -> [String: Int64] {
        guard !categoryIDs.isEmpty else { return [:] }
        let base = total / Int64(categoryIDs.count)
        var remainder = total % Int64(categoryIDs.count)
        var result: [String: Int64] = [:]
        for id in categoryIDs.sorted() {
            let extra: Int64 = remainder > 0 ? 1 : 0
            result[id] = base + extra
            remainder -= extra
        }
        return result
    }

    private func fail(_ error: DemoMutationError) -> Bool {
        errorMessage = error.localizedDescription
        return false
    }

    static let seedAccounts: [DemoAccount] = [
        .init(id: "checking", name: "Household Checking", kind: .checking, balance: 684032, cleared: 671532),
        .init(id: "savings", name: "High-Yield Savings", kind: .savings, balance: 1425000, cleared: 1425000),
        .init(id: "cash", name: "Wallet Cash", kind: .cash, balance: 18000, cleared: 18000),
        .init(id: "visa", name: "Everyday Visa", kind: .credit, balance: -142864, cleared: -130364, paymentReserved: 121250, fundedSpending: 48264, unfundedSpending: 21614, apr: 20.49, minimumPayment: 4500, dueText: "Due Sep 18"),
        .init(id: "mastercard", name: "Travel Mastercard", kind: .credit, balance: -36421, cleared: -36421, paymentReserved: 36421, fundedSpending: 18210, dueText: "Due Sep 24"),
        .init(id: "auto", name: "Auto Loan", kind: .loan, balance: -1875000, cleared: -1875000, isOnBudget: false, apr: 6.25, minimumPayment: 41200, dueText: "Due Oct 1"),
        .init(id: "mortgage", name: "Home Mortgage", kind: .mortgage, balance: -23840000, cleared: -23840000, isOnBudget: false, apr: 3.75, minimumPayment: 184500, dueText: "Due Oct 1"),
        .init(id: "home", name: "Home Value", kind: .asset, balance: 39200000, cleared: 39200000, isOnBudget: false)
    ]

    static let seedCategories: [DemoCategory] = [
        .init(id:"mortgage",group:"Housing",name:"Mortgage",icon:"house.fill",assigned:184500,activity:-184500,available:184500,target:184500,pinned:true),
        .init(id:"electric",group:"Housing",name:"Electric",icon:"bolt.fill",assigned:16500,activity:-14820,available:1680,target:16500),
        .init(id:"water",group:"Housing",name:"Water",icon:"drop.fill",assigned:8500,activity:-7200,available:1300,target:8500),
        .init(id:"internet",group:"Housing",name:"Internet",icon:"wifi",assigned:7900,activity:-7900,available:7900,target:7900),
        .init(id:"groceries",group:"Food",name:"Groceries",icon:"cart.fill",assigned:72000,activity:-48264,available:23736,target:72000,pinned:true),
        .init(id:"dining",group:"Food",name:"Dining Out",icon:"fork.knife",assigned:22000,activity:-26840,available:-4840,target:22000),
        .init(id:"fuel",group:"Transportation",name:"Fuel",icon:"fuelpump.fill",assigned:28000,activity:-18520,available:9480,target:30000),
        .init(id:"maintenance",group:"Transportation",name:"Car Maintenance",icon:"wrench.and.screwdriver.fill",assigned:15000,activity:0,available:84500,target:120000,targetDate:"December 2026"),
        .init(id:"medical",group:"True Expenses",name:"Medical",icon:"cross.case.fill",assigned:10000,activity:-4500,available:35500,target:50000),
        .init(id:"repair",group:"True Expenses",name:"Home Repair",icon:"hammer.fill",assigned:25000,activity:0,available:186000,target:300000),
        .init(id:"christmas",group:"True Expenses",name:"Christmas",icon:"gift.fill",assigned:35000,activity:0,available:188000,target:300000,targetDate:"December 2026"),
        .init(id:"subscriptions",group:"True Expenses",name:"Annual Subscriptions",icon:"calendar.badge.clock",assigned:12000,activity:0,available:74000,target:120000,targetDate:"January 2027"),
        .init(id:"buffer",group:"True Expenses",name:"General Buffer",icon:"tray.full.fill",assigned:35000,activity:0,available:35000,target:35000),
        .init(id:"emergency",group:"Goals",name:"Emergency Fund",icon:"shield.fill",assigned:50000,activity:0,available:1125000,target:1500000,pinned:true),
        .init(id:"vacation",group:"Goals",name:"Vacation",icon:"airplane",assigned:40000,activity:0,available:385000,target:600000,targetDate:"June 2027"),
        .init(id:"cnc",group:"Goals",name:"CNC Machine",icon:"gearshape.2.fill",assigned:25000,activity:0,available:64000,target:200000,targetDate:"June 2027",pinned:true),
        .init(id:"newcar",group:"Goals",name:"New Car",icon:"car.side.fill",assigned:30000,activity:0,available:420000,target:2500000,targetDate:"September 2029"),
        .init(id:"rey",group:"Personal",name:"Rey Spending",icon:"person.fill",assigned:20000,activity:-8300,available:11700,target:20000),
        .init(id:"partner",group:"Personal",name:"Jordan Spending",icon:"person.fill",assigned:20000,activity:-4200,available:15800,target:20000),
        .init(id:"alexallow",group:"Kids",name:"Alex Allowance",icon:"gamecontroller.fill",assigned:4800,activity:-2200,available:4200,target:4800,delegatedTo:.alex),
        .init(id:"alexsave",group:"Kids",name:"Alex Savings",icon:"banknote.fill",assigned:2000,activity:0,available:18500,target:50000,targetDate:"March 2027",delegatedTo:.alex),
        .init(id:"alexgive",group:"Kids",name:"Giving",icon:"heart.fill",assigned:0,activity:0,available:0,target:nil,delegatedTo:.alex),
        .init(id:"miaallow",group:"Kids",name:"Mia Allowance",icon:"paintpalette.fill",assigned:3200,activity:-1200,available:2800,target:3200,delegatedTo:.mia),
        .init(id:"miabike",group:"Kids",name:"Mia Bike Goal",icon:"bicycle",assigned:1200,activity:0,available:18500,target:50000,targetDate:"May 2027",delegatedTo:.mia)
    ]

    static var seedTransactions: [DemoTransaction] {
        var items: [DemoTransaction] = [
            .init(id:"t1",date:.demo(monthsAgo:0,day:3),payee:"Fresh Market",memo:"Weekly groceries",accountID:"visa",categoryIDs:["groceries"],amount:-12500,member:.rey,cleared:false,flag:"Groceries",attachmentName:"receipt-placeholder.jpg"),
            .init(id:"t2",date:.demo(monthsAgo:0,day:2),payee:"Payroll",memo:"September paycheck",accountID:"checking",categoryIDs:[],amount:375000,member:.rey,cleared:true),
            .init(id:"t3",date:.demo(monthsAgo:0,day:8),payee:"Corner Bistro",memo:"Family dinner",accountID:"mastercard",categoryIDs:["dining"],amount:-8640,member:.partner,cleared:true),
            .init(id:"t4",date:.demo(monthsAgo:0,day:11),payee:"Home Center",memo:"Paint and repair supplies",accountID:"checking",categoryIDs:["repair","maintenance"],amount:-12640,member:.rey,cleared:true,flag:"Split"),
            .init(id:"t5",date:.demo(monthsAgo:0,day:15),payee:"Auto Loan Payment",memo:"Principal $315 · Interest $97",accountID:"checking",categoryIDs:["maintenance"],amount:-41200,member:.rey,cleared:true),
            .init(id:"t6",date:.demo(monthsAgo:0,day:20),payee:"Weekly Allowance",memo:"Alex: spend, save, give",accountID:"checking",categoryIDs:["alexallow","alexsave"],amount:-2000,member:.alex,cleared:true,scheduled:true)
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
