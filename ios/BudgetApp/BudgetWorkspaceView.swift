import BudgetAPI
import SwiftUI
import Charts

enum Theme {
    static let accent = Color(red: 0.10, green: 0.40, blue: 0.36)
    static let healthy = Color(red: 0.12, green: 0.48, blue: 0.33)
    static let attention = Color(red: 0.80, green: 0.48, blue: 0.08)
    static let danger = Color(red: 0.74, green: 0.18, blue: 0.20)
    static let projected = Color.indigo
}

struct FreshBudgetActivationState: Equatable {
    let accountCount: Int
    let groupCount: Int
    let categoryCount: Int
    let canManageStructure: Bool

    var needsAccount: Bool { accountCount == 0 }
    var needsGroup: Bool { groupCount == 0 }
    var needsCategory: Bool { categoryCount == 0 }
    var showsAddAccount: Bool { canManageStructure }
    var showsCreateGroup: Bool { needsGroup && canManageStructure }
    var showsAddCategory: Bool { !needsGroup && needsCategory && canManageStructure }
    var showsNormalPlan: Bool { !needsGroup && !needsCategory }
}

private struct WorkspaceSnapshot {
    var accounts: [APIAccount]; var accountBalances: [String: APIAccountBalance]; var categories: [APICategory]; var groups: [APICategoryGroup]
    var transactions: [APITransaction]; var summary: APIMonthSummary?
    var requests: [APIFinancialRequest]; var allowances: [APIAllowancePlan]
    var spending: APISpendingReport?; var income: APIIncomeSpendingReport?
    var delegated: APIDelegatedBudget?; var forecast: APIForecast?
    var members: [APIHouseholdMember]; var delegatedBudgets: [APIDelegatedBudget]
    var allocationOperations: [APIAllocationOperation] = []
    var targets: [APICategoryTarget] = []
    var schedules: [APIScheduledTransaction] = []
}

private struct WorkspaceReportQuery {
    let start: Date; let end: Date; let accountID: String; let categoryID: String
    let categoryGroup: String; let payee: String; let memberID: String
    let transactionType: String; let cleared: String; let includeTracking: Bool
}

@MainActor
private protocol WorkspaceDataSource: AnyObject {
    var budget: APIBudget { get }
    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot
}

@MainActor
private final class DemoWorkspaceDataSource: WorkspaceDataSource {
    let demo: DemoStore
    let budget: APIBudget

    init(fresh: Bool = false) {
        let store = DemoStore()
        if fresh || ProcessInfo.processInfo.arguments.contains("--demo-fresh-budget") {
            store.accounts = []
            store.categories = []
            store.transactions = []
            store.groupOrder = []
            store.setUnassigned(0)
        }
        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--demo-persona=") })?.split(separator: "=").last,
           let persona = DemoPersona.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) { store.persona = persona }
        demo = store
        let restricted = store.persona.isChild
        budget = APIBudget(
            id: "demo-budget", householdID: "demo-household", name: "Rivera Household", currencyCode: "USD",
            effectivePermission: restricted ? .contribute : .owner,
            capabilities: restricted ? ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances", "create_transaction", "edit_transaction", "delete_transaction", "request_money", "move_money", "manage_own_categories"] : nil
        )
    }

    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot {
        let visibleAccounts = demo.visibleAccounts
        let visibleCategories = demo.visibleCategories
        let categoryIDs = Set(visibleCategories.map(\.id))
        let accountRows: [APIAccount] = try decode(visibleAccounts.map { ["id": $0.id, "budget_id": budget.id, "name": $0.name, "account_type": $0.kind.rawValue, "is_on_budget": $0.kind != .asset, "is_closed": false, "reconciled_balance_minor": $0.cleared, "payment_category_id": NSNull()] })
        let accountBalanceRows: [APIAccountBalance] = try decode(visibleAccounts.map { ["account_id": $0.id, "currency_code": "USD", "cleared_balance_minor": $0.cleared, "uncleared_balance_minor": $0.balance - $0.cleared, "working_balance_minor": $0.balance, "reconciled_balance_minor": $0.cleared] })
        let groupNames = demo.isRestricted ? demo.groupOrder.filter { name in visibleCategories.contains { $0.group == name } } : demo.groupOrder
        let groupIDs = Dictionary(uniqueKeysWithValues: groupNames.map { ($0, "demo-group-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))") })
        let groupRows: [APICategoryGroup] = try decode(groupNames.enumerated().map { ["id": groupIDs[$0.element]!, "budget_id": budget.id, "name": $0.element, "sort_order": $0.offset, "is_archived": demo.archivedGroups.contains($0.element)] })
        let categoryRows: [APICategory] = try decode(visibleCategories.enumerated().map { index, item in ["id": item.id, "budget_id": budget.id, "group_id": groupIDs[item.group]!, "name": item.name, "sort_order": index, "is_archived": item.isHidden, "system_type": NSNull(), "linked_account_id": NSNull(), "delegated_user_id": item.delegatedTo?.rawValue.lowercased() ?? NSNull()] })
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.dateFormat = "yyyy-MM-dd"
        let transactionRows: [APITransaction] = try decode(demo.visibleTransactions.map { item in
            let ids = item.categoryIDs.filter { categoryIDs.contains($0) }
            let splitBase = ids.isEmpty ? 0 : item.amount / Int64(ids.count)
            var remainder = ids.isEmpty ? 0 : item.amount % Int64(ids.count)
            let splits: [[String: Any]] = ids.count > 1 ? ids.enumerated().map { index, id in let extra: Int64 = remainder == 0 ? 0 : (remainder > 0 ? 1 : -1); if remainder != 0 { remainder -= extra }; return ["id": "\(item.id)-\(index)", "category_id": id, "amount_minor": item.categoryAmounts[id] ?? splitBase + extra, "memo": ""] } : []
            return ["id": item.id, "account_id": item.accountID, "category_id": ids.count == 1 ? ids[0] : NSNull(), "amount_minor": item.amount, "occurred_on": dateFormatter.string(from: item.date), "payee_name": item.payee, "memo": item.memo, "is_cleared": item.cleared, "is_reconciled": item.reconciled, "transfer_id": item.transferID.map { $0 as Any } ?? NSNull(), "flag": item.flag.map { $0 as Any } ?? NSNull(), "tags": item.tags, "attachment_metadata": item.attachmentName.map { [["name": $0]] } ?? [], "splits": splits]
        })
        let month = String(BudgetWorkspaceStore.dateString(planMonth).prefix(7)) + "-01"
        // Best-effort credit spend per category from demo transactions on credit-kind accounts,
        // so the demo classifies overspending as cash vs credit like the live server does.
        let creditAccountIDs = Set(demo.accounts.filter { $0.kind == .credit }.map(\.id))
        var creditSpend: [String: Int64] = [:]
        for item in demo.visibleTransactions where creditAccountIDs.contains(item.accountID) {
            let ids = item.categoryIDs
            guard !ids.isEmpty else { continue }
            let base = item.amount / Int64(ids.count)
            for id in ids { creditSpend[id, default: 0] += item.categoryAmounts[id] ?? base }
        }
        let summaryRows: [[String: Any]] = visibleCategories.map { item -> [String: Any] in
            let recommended: Int64
            if let target = item.target, item.targetIsActive {
                if item.targetType == "monthly_funding" {
                    recommended = max(target, item.targetMinimumContribution)
                } else if item.targetType == "savings_balance" {
                    recommended = max(target - max(item.available - item.assigned, 0), item.targetMinimumContribution)
                } else {
                    let due = item.targetDate.flatMap { dateFormatter.date(from: $0) } ?? planMonth
                    let current = Calendar.current.dateComponents([.year, .month], from: planMonth)
                    let targetMonth = Calendar.current.dateComponents([.year, .month], from: due)
                    let periods = max(1, ((targetMonth.year ?? current.year ?? 0) - (current.year ?? 0)) * 12 + (targetMonth.month ?? current.month ?? 1) - (current.month ?? 1) + 1)
                    let gap = max(target - max(item.available - item.assigned, 0), 0)
                    recommended = max((gap + Int64(periods) - 1) / Int64(periods), item.targetMinimumContribution)
                }
            } else { recommended = 0 }
            let overspent = max(-item.available, 0)
            let creditSpent = max(-(creditSpend[item.id] ?? 0), 0)
            let creditOverspent = min(overspent, creditSpent)
            return ["category_id": item.id, "name": item.name, "assigned_minor": item.assigned, "activity_minor": item.activity, "carried_available_minor": max(item.available - item.assigned - item.activity, 0), "available_minor": item.available, "is_overspent": item.available < 0, "cash_overspent_minor": overspent - creditOverspent, "credit_overspent_minor": creditOverspent, "funded_credit_spending_minor": max(creditSpent - creditOverspent, 0), "target_type": item.target == nil ? NSNull() : item.targetType, "target_amount_minor": item.target.map { $0 as Any } ?? NSNull(), "target_date": item.targetDate.map { $0 as Any } ?? NSNull(), "recommended_contribution_minor": recommended, "underfunded_minor": max(recommended - max(item.assigned, 0), 0)]
        }
        let summary: APIMonthSummary = try decode(["month": month, "currency_code": "USD", "ready_to_assign_minor": demo.readyToAssign, "total_assigned_minor": visibleCategories.reduce(0) { $0 + $1.assigned }, "total_overspent_minor": visibleCategories.reduce(0) { $0 + max(-$1.available, 0) }, "allocation_version": 1, "categories": summaryRows])
        let start = report.start
        let included = demo.visibleTransactions.filter { item in
            item.date >= start && item.date <= report.end
            && (report.accountID.isEmpty || item.accountID == report.accountID)
            && (report.categoryID.isEmpty || item.categoryIDs.contains(report.categoryID))
            && (report.categoryGroup.isEmpty || item.categoryIDs.contains { id in visibleCategories.first(where: { $0.id == id })?.group == report.categoryGroup })
            && (report.payee.isEmpty || item.payee == report.payee)
            && (report.memberID.isEmpty || item.member.rawValue.lowercased() == report.memberID)
            && (report.cleared == "all" || item.cleared == (report.cleared == "cleared"))
            && (report.transactionType.isEmpty
                || (report.transactionType == "transfer" && item.transferID != nil)
                || (report.transactionType == "income" && item.transferID == nil && item.amount > 0 && item.categoryIDs.isEmpty)
                || (report.transactionType == "spending" && item.transferID == nil && item.amount < 0 && !item.categoryIDs.isEmpty)
                || (report.transactionType == "refund" && item.transferID == nil && item.amount > 0 && !item.categoryIDs.isEmpty))
        }
        let spendingRows: [[String: Any]] = visibleCategories.compactMap { category in let contributing = included.filter { $0.amount < 0 && $0.categoryIDs.contains(category.id) }; let total = contributing.reduce(Int64(0)) { $0 + abs($1.amount) / Int64(max($1.categoryIDs.count, 1)) }; return total == 0 ? nil : ["category_id": category.id, "category_name": category.name, "category_group": category.group, "spending_minor": total, "transaction_ids": contributing.map(\.id)] }
        let spending: APISpendingReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "total_spending_minor": spendingRows.reduce(Int64(0)) { $0 + ($1["spending_minor"] as? Int64 ?? 0) }, "categories": spendingRows])
        let incomeValue = included.filter { $0.amount > 0 && $0.categoryIDs.isEmpty }.reduce(Int64(0)) { $0 + $1.amount }
        let spendingValue = included.filter { $0.amount < 0 && !$0.categoryIDs.isEmpty }.reduce(Int64(0)) { $0 + abs($1.amount) }
        let income: APIIncomeSpendingReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "income_minor": incomeValue, "spending_minor": spendingValue, "difference_minor": incomeValue - spendingValue, "savings_rate": incomeValue > 0 ? Double(incomeValue - spendingValue) / Double(incomeValue) : NSNull(), "income_transaction_ids": included.filter { $0.amount > 0 && $0.categoryIDs.isEmpty }.map(\.id), "spending_transaction_ids": included.filter { $0.amount < 0 && !$0.categoryIDs.isEmpty }.map(\.id)])
        let delegated: APIDelegatedBudget? = demo.isRestricted ? try decode(["id": "demo-delegated", "budget_id": budget.id, "user_id": demo.persona.rawValue.lowercased(), "pool_category_id": visibleCategories.first?.id ?? "", "authority_minor": demo.delegatedAuthority, "assigned_minor": demo.delegatedAssigned, "available_to_assign_minor": demo.delegatedReadyToAssign, "allow_category_creation": true, "allow_reallocation": true, "rules": []]) : nil
        let requestRows: [APIFinancialRequest] = try decode(demo.requests.filter { !demo.isRestricted || $0.member == demo.persona }.map { item -> [String: Any] in ["id": item.id, "requester_user_id": item.member.rawValue.lowercased(), "request_type": "additional_allocation", "destination_category_id": item.categoryID, "requested_amount_minor": item.amount, "reason": item.reason, "status": item.status.lowercased().replacingOccurrences(of: " ", with: "_"), "version": item.status == "Pending" ? 0 : 1, "approved_amount_minor": item.approvedAmount.map { $0 as Any } ?? NSNull(), "source_category_id": NSNull(), "allocation_operation_id": NSNull(), "actions": []] })
        // Deterministic allocation history so the same production category-detail view shows
        // realistic movements (assignment, move in, move out) in demo mode. Same DTO shape as live.
        let actor = demo.persona.rawValue.lowercased()
        var allocationRows: [[String: Any]] = []
        for item in visibleCategories where item.assigned != 0 {
            allocationRows.append(["id": "demo-alloc-\(item.id)", "budget_id": budget.id, "occurred_on": month, "kind": "assignment", "actor_user_id": actor, "note": "Assigned \(item.name)", "source": "manual", "allocation_version": 1, "postings": [["bucket": "ready_to_assign", "category_id": NSNull(), "amount_minor": -item.assigned], ["bucket": "category", "category_id": item.id, "amount_minor": item.assigned]]])
        }
        if visibleCategories.count >= 2 {
            let source = visibleCategories[0], destination = visibleCategories[1]
            let moveAmount: Int64 = 5000
            allocationRows.append(["id": "demo-move", "budget_id": budget.id, "occurred_on": dateFormatter.string(from: report.end), "kind": "category_transfer", "actor_user_id": actor, "note": demo.isRestricted ? "Delegated move within your budget" : "Moved money between categories", "source": "manual", "allocation_version": 1, "postings": [["bucket": "category", "category_id": source.id, "amount_minor": -moveAmount], ["bucket": "category", "category_id": destination.id, "amount_minor": moveAmount]]])
        }
        let allocationOperations: [APIAllocationOperation] = try decode(allocationRows)
        let targetRows = visibleCategories.compactMap { item -> APICategoryTarget? in
            guard let amount = item.target else { return nil }
            return APICategoryTarget(id: "demo-\(item.id)", categoryID: item.id, targetType: item.targetType, targetAmountMinor: amount, targetDate: item.targetDate, recurrenceMonths: item.targetRecurrenceMonths, minimumContributionMinor: item.targetMinimumContribution, priority: item.targetPriority, isActive: item.targetIsActive)
        }
        let scheduleRows: [APIScheduledTransaction] = try decode(demo.schedules.filter { item in
            visibleAccounts.contains { $0.id == item.accountID }
                && (item.destinationAccountID == nil || visibleAccounts.contains { $0.id == item.destinationAccountID })
                && (item.categoryID == nil || categoryIDs.contains(item.categoryID!))
        }.map { item in ["id": item.id, "budget_id": budget.id, "account_id": item.accountID, "destination_account_id": item.destinationAccountID.map { $0 as Any } ?? NSNull(), "category_id": item.categoryID.map { $0 as Any } ?? NSNull(), "name": item.name, "amount_minor": item.amount, "next_date": item.nextDate, "recurrence_unit": item.recurrenceUnit, "interval_count": item.intervalCount, "memo": item.memo, "is_active": item.isActive, "last_realized_on": item.lastRealizedOn.map { $0 as Any } ?? NSNull()] })
        let forecastStart = Date.demo(monthsAgo: 0, day: 5), forecastThrough = Calendar.current.date(byAdding: .day, value: 90, to: forecastStart)!
        var projected = Dictionary(uniqueKeysWithValues: visibleAccounts.map { ($0.id, $0.balance) })
        var occurrenceRows: [[String: Any]] = []
        for item in scheduleRows where item.isActive {
            var occurrence = BudgetWorkspaceStore.parseDate(item.nextDate)
            for _ in 0..<400 where occurrence <= forecastThrough {
                if occurrence >= forecastStart {
                    if let destination = item.destinationAccountID { projected[item.accountID, default: 0] -= item.amountMinor; projected[destination, default: 0] += item.amountMinor }
                    else { projected[item.accountID, default: 0] += item.amountMinor }
                    occurrenceRows.append(["scheduled_transaction_id": item.id, "name": item.name, "occurred_on": BudgetWorkspaceStore.dateString(occurrence), "account_id": item.accountID, "destination_account_id": item.destinationAccountID.map { $0 as Any } ?? NSNull(), "category_id": item.categoryID.map { $0 as Any } ?? NSNull(), "amount_minor": item.amountMinor])
                }
                guard let next = BudgetWorkspaceStore.nextScheduledDate(from: occurrence, unit: item.recurrenceUnit, interval: item.intervalCount) else { break }
                occurrence = next
            }
        }
        let forecastAccounts = visibleAccounts.map { ["account_id": $0.id, "name": $0.name, "actual_balance_minor": $0.balance, "projected_balance_minor": projected[$0.id] ?? $0.balance] as [String: Any] }
        let actualTotal = visibleAccounts.reduce(Int64(0)) { $0 + $1.balance }, projectedTotal = projected.values.reduce(Int64(0), +)
        let demoForecast: APIForecast = try decode(["as_of": BudgetWorkspaceStore.dateString(forecastStart), "through": BudgetWorkspaceStore.dateString(forecastThrough), "currency_code": budget.currencyCode, "actual_total_on_budget_minor": actualTotal, "projected_total_on_budget_minor": projectedTotal, "lowest_projected_total_minor": min(actualTotal, projectedTotal), "accounts": forecastAccounts, "occurrences": occurrenceRows])
        return WorkspaceSnapshot(accounts: accountRows, accountBalances: Dictionary(uniqueKeysWithValues: accountBalanceRows.map { ($0.accountID, $0) }), categories: categoryRows, groups: groupRows, transactions: transactionRows, summary: summary, requests: requestRows, allowances: [], spending: spending, income: income, delegated: delegated, forecast: demoForecast, members: [], delegatedBudgets: [], allocationOperations: allocationOperations, targets: targetRows, schedules: scheduleRows)
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
}

@MainActor
final class BudgetWorkspaceStore: ObservableObject {
    let budget: APIBudget
    @Published var summary: APIMonthSummary?
    @Published var accounts: [APIAccount] = []
    @Published var accountBalances: [String: APIAccountBalance] = [:]
    @Published var categories: [APICategory] = []
    @Published var groups: [APICategoryGroup] = []
    @Published var transactions: [APITransaction] = []
    @Published var requests: [APIFinancialRequest] = []
    @Published var allowances: [APIAllowancePlan] = []
    @Published var spendingReport: APISpendingReport?
    @Published var incomeReport: APIIncomeSpendingReport?
    @Published var delegatedBudget: APIDelegatedBudget?
    @Published var householdMembers: [APIHouseholdMember] = []
    @Published var delegatedBudgets: [APIDelegatedBudget] = []
    @Published var allocationOperations: [APIAllocationOperation] = []
    @Published var targets: [String: APICategoryTarget] = [:]
    @Published var scheduledTransactions: [APIScheduledTransaction] = []
    @Published var forecast: APIForecast?
    @Published var reportPeriod = "30d"
    @Published var customReportStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @Published var customReportEnd = Date()
    @Published var reportAccountID = ""
    @Published var reportCategoryID = ""
    @Published var reportCategoryGroup = ""
    @Published var reportPayee = ""
    @Published var reportMemberID = ""
    @Published var reportTransactionType = ""
    @Published var reportCleared = "all"
    @Published var includeTrackingAccounts = false
    @Published var planMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let dataSource: WorkspaceDataSource?
    private var liveServerURL: URL?
    private var liveToken: String?

    init(budget: APIBudget) { self.budget = budget; dataSource = nil }
    private init(dataSource: WorkspaceDataSource) { self.budget = dataSource.budget; self.dataSource = dataSource }
    static func demo(fresh: Bool = false) -> BudgetWorkspaceStore { BudgetWorkspaceStore(dataSource: DemoWorkspaceDataSource(fresh: fresh)) }

    func load(serverURL: URL, token: String) async {
        liveServerURL = serverURL; liveToken = token
        isLoading = true
        defer { isLoading = false }
        do {
            if let dataSource {
                let range = reportRange()
                let query = WorkspaceReportQuery(start: range.0, end: range.1, accountID: reportAccountID, categoryID: reportCategoryID, categoryGroup: reportCategoryGroup, payee: reportPayee, memberID: reportMemberID, transactionType: reportTransactionType, cleared: reportCleared, includeTracking: includeTrackingAccounts)
                let value = try await dataSource.snapshot(planMonth: planMonth, report: query)
                accounts = value.accounts; accountBalances = value.accountBalances; categories = value.categories; groups = value.groups; transactions = value.transactions
                summary = value.summary; requests = value.requests; allowances = value.allowances; spendingReport = value.spending
                incomeReport = value.income; delegatedBudget = value.delegated; forecast = value.forecast
                householdMembers = value.members; delegatedBudgets = value.delegatedBudgets; allocationOperations = value.allocationOperations; errorMessage = nil
                targets = Dictionary(uniqueKeysWithValues: value.targets.map { ($0.categoryID, $0) })
                scheduledTransactions = value.schedules
                return
            }
            let client = try APIClient(baseURL: serverURL)
            let month = Self.dateString(planMonth).prefix(7) + "-01"
            let range = reportRange(); let start = Self.dateString(range.0); let end = Self.dateString(range.1)
            async let loadedAccounts = client.accounts(budgetID: budget.id, token: token)
            async let loadedTransactions = client.transactions(budgetID: budget.id, token: token)
            async let loadedCategories = client.categories(budgetID: budget.id, token: token)
            async let loadedGroups = client.categoryGroups(budgetID: budget.id, token: token)
            async let loadedSummary = client.monthSummary(budgetID: budget.id, month: String(month), token: token)
            async let loadedSpending = client.spendingReport(
                budgetID: budget.id, startDate: start, endDate: end,
                accountIDs: reportAccountID.isEmpty ? [] : [reportAccountID],
                categoryIDs: reportCategoryID.isEmpty ? [] : [reportCategoryID],
                categoryGroups: reportCategoryGroup.isEmpty ? [] : [reportCategoryGroup],
                memberIDs: reportMemberID.isEmpty ? [] : [reportMemberID],
                payees: reportPayee.isEmpty ? [] : [reportPayee],
                transactionType: reportTransactionType.isEmpty ? nil : reportTransactionType,
                cleared: reportCleared == "all" ? nil : reportCleared == "cleared",
                includeTracking: includeTrackingAccounts, token: token
            )
            async let loadedIncome = client.incomeSpendingReport(
                budgetID: budget.id, startDate: start, endDate: end,
                accountIDs: reportAccountID.isEmpty ? [] : [reportAccountID],
                memberIDs: reportMemberID.isEmpty ? [] : [reportMemberID],
                payees: reportPayee.isEmpty ? [] : [reportPayee],
                cleared: reportCleared == "all" ? nil : reportCleared == "cleared",
                includeTracking: includeTrackingAccounts, token: token
            )
            (accounts, transactions, categories, groups, summary, spendingReport, incomeReport) = try await (
                loadedAccounts, loadedTransactions, loadedCategories, loadedGroups, loadedSummary, loadedSpending, loadedIncome
            )
            if budget.can("view_allocation_history") { allocationOperations = (try? await client.allocationOperations(budgetID: budget.id, token: token)) ?? [] }
            scheduledTransactions = budget.can("view_transactions") ? (try await client.scheduledTransactions(budgetID: budget.id, includeInactive: true, token: token)) : []
            targets = Dictionary(uniqueKeysWithValues: await withTaskGroup(of: (String, APICategoryTarget?).self) { group in for category in categories { group.addTask { (category.id, try? await client.categoryTarget(budgetID: self.budget.id, categoryID: category.id, token: token)) } }; var values: [(String, APICategoryTarget)] = []; for await (id, target) in group { if let target { values.append((id, target)) } }; return values })
            accountBalances = Dictionary(uniqueKeysWithValues: await withTaskGroup(of: (String, APIAccountBalance?).self) { group in
                for account in accounts { group.addTask { (account.id, try? await client.accountBalance(budgetID: self.budget.id, accountID: account.id, token: token)) } }
                var values: [(String, APIAccountBalance)] = []; for await (id, balance) in group { if let balance { values.append((id, balance)) } }; return values
            })
            if budget.can("request_money") || budget.can("approve_request") {
                requests = (try? await client.financialRequests(budgetID: budget.id, token: token)) ?? []
            }
            allowances = (try? await client.allowancePlans(budgetID: budget.id, token: token)) ?? []
            delegatedBudget = try? await client.delegatedBudget(budgetID: budget.id, token: token)
            if budget.can("view_account_balances") {
                let horizon = Calendar.current.date(byAdding: .day, value: 90, to: Date())!
                forecast = try? await client.forecast(budgetID: budget.id, through: Self.dateString(horizon), token: token)
            }
            if budget.can("manage_allowances") {
                householdMembers = (try? await client.householdMembers(householdID: budget.householdID, token: token)) ?? []
                delegatedBudgets = (try? await client.delegatedBudgets(budgetID: budget.id, token: token)) ?? []
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        if let liveServerURL, let liveToken { await load(serverURL: liveServerURL, token: liveToken) }
        else if dataSource != nil { await load(serverURL: URL(string: "http://localhost")!, token: "demo") }
    }

    func createTransaction(_ value: APITransactionCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            let amounts = value.categoryID.map { [$0: value.amountMinor] } ?? Dictionary(uniqueKeysWithValues: value.splits.map { ($0.categoryID, $0.amountMinor) })
            demoSource.demo.createTransaction(payee: value.payeeName, signedAmount: value.amountMinor, date: Self.parseDate(value.occurredOn), accountID: value.accountID, categoryAmounts: amounts, memo: value.memo, cleared: value.isCleared, flag: value.flag, tags: value.tags, attachmentName: value.attachmentMetadata.first?["name"])
        } else { _ = try await liveClient().createTransaction(budgetID: budget.id, transaction: value, token: liveToken!) }
        await refresh()
    }

    func updateTransaction(id: String, value: APITransactionCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            let amounts = value.categoryID.map { [$0: value.amountMinor] } ?? Dictionary(uniqueKeysWithValues: value.splits.map { ($0.categoryID, $0.amountMinor) })
            guard demoSource.demo.updateTransactionSigned(id: id, payee: value.payeeName, signedAmount: value.amountMinor, date: Self.parseDate(value.occurredOn), accountID: value.accountID, categoryAmounts: amounts, memo: value.memo, cleared: value.isCleared, flag: value.flag, tags: value.tags, attachmentName: value.attachmentMetadata.first?["name"]) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else { _ = try await liveClient().updateTransaction(budgetID: budget.id, transactionID: id, transaction: value, token: liveToken!) }
        await refresh()
    }

    func deleteTransaction(id: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard demoSource.demo.deleteTransaction(id: id) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else { try await liveClient().deleteTransaction(budgetID: budget.id, transactionID: id, token: liveToken!) }
        await refresh()
    }

    func createTransfer(_ value: APITransferCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard demoSource.demo.transfer(amount: value.amountMinor, from: value.sourceAccountID, to: value.destinationAccountID, memo: value.memo, cleared: value.isCleared) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else { _ = try await liveClient().createTransfer(budgetID: budget.id, transfer: value, token: liveToken!) }
        await refresh()
    }

    func reconcile(accountID: String, statementBalance: Int64, throughDate: String, createAdjustment: Bool, reason: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard demoSource.demo.reconcile(accountID: accountID, statementBalance: statementBalance) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else {
            let cleared = transactions.filter { $0.accountID == accountID && $0.isCleared }.reduce(0) { $0 + $1.amountMinor }
            _ = try await liveClient().reconcileAccount(budgetID: budget.id, accountID: accountID, request: APIReconcileRequest(statementBalanceMinor: statementBalance, throughDate: throughDate, createAdjustment: createAdjustment, adjustmentReason: reason, expectedClearedBalanceMinor: cleared), token: liveToken!)
        }
        await refresh()
    }

    func updateAssignment(categoryID: String, month: String, assignedMinor: Int64, expectedVersion: Int) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard !demoSource.demo.isRestricted, let index = demoSource.demo.categories.firstIndex(where: { $0.id == categoryID }) else { throw workspaceError("Delegated members allocate from their own pool by moving money.") }
            let delta = assignedMinor - demoSource.demo.categories[index].assigned
            guard delta <= demoSource.demo.readyToAssign else { throw workspaceError("Not enough real money to assign.") }
            demoSource.demo.categories[index].assigned += delta; demoSource.demo.categories[index].available += delta
            demoSource.demo.setUnassigned(demoSource.demo.readyToAssign - delta)
        } else { _ = try await liveClient().updateAssignment(budgetID: budget.id, categoryID: categoryID, month: month, assignedMinor: assignedMinor, expectedAllocationVersion: expectedVersion, token: liveToken!) }
        await refresh()
    }

    func moveAllocation(_ value: APIAllocationTransferCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard demoSource.demo.move(amount: value.amountMinor, from: value.sourceCategoryID, to: value.destinationCategoryID) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else { _ = try await liveClient().transferAllocation(budgetID: budget.id, transfer: value, token: liveToken!) }
        await refresh()
    }

    func createCategory(groupID: String, newGroupName: String, name: String, delegatedUserID: String?) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            let group = groups.first(where: { $0.id == groupID })?.name ?? newGroupName
            guard demoSource.demo.createCategory(name: name, group: group) else { throw workspaceError(demoSource.demo.errorMessage) }
        } else {
            let client = try liveClient(); var targetGroupID = groupID
            if !newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { targetGroupID = try await client.createCategoryGroup(budgetID: budget.id, group: APICategoryGroupCreate(name: newGroupName), token: liveToken!).id }
            _ = try await client.createCategory(budgetID: budget.id, category: APICategoryCreate(groupID: targetGroupID, name: name, delegatedUserID: delegatedUserID), token: liveToken!)
        }
        await refresh()
    }

    func createGroup(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw workspaceError("Enter a category group name.") }
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            if !demoSource.demo.groupOrder.contains(trimmed) { demoSource.demo.groupOrder.append(trimmed) }
        } else {
            _ = try await liveClient().createCategoryGroup(
                budgetID: budget.id,
                group: APICategoryGroupCreate(name: trimmed),
                token: liveToken!
            )
        }
        await refresh()
    }

    func createAccount(_ value: APIAccountCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource { demoSource.demo.createAccount(name: value.name, type: value.accountType, isOnBudget: value.isOnBudget, startingBalance: value.startingBalanceMinor) }
        else { _ = try await liveClient().createAccount(budgetID: budget.id, account: value, token: liveToken!) }
        await refresh()
    }

    func createRequest(_ value: APIFinancialRequestCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            demoSource.demo.requests.insert(.init(id: UUID().uuidString, member: demoSource.demo.persona, amount: value.requestedAmountMinor, categoryID: value.destinationCategoryID, reason: value.reason, status: "Pending", date: .demo(monthsAgo: 0, day: 30)), at: 0)
        } else { _ = try await liveClient().createFinancialRequest(budgetID: budget.id, request: value, token: liveToken!) }
        await refresh()
    }

    func updateCategory(id: String, value: APICategoryUpdate, delegatedUserID: String?) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            guard let index = demoSource.demo.categories.firstIndex(where: { $0.id == id }) else { throw workspaceError("Category not found.") }
            demoSource.demo.categories[index].name = value.name
            demoSource.demo.categories[index].group = groups.first(where: { $0.id == value.groupID })?.name ?? demoSource.demo.categories[index].group
            demoSource.demo.categories[index].isHidden = value.isArchived
        } else {
            let client = try liveClient(); let existing = categories.first(where: { $0.id == id })
            _ = try await client.updateCategory(budgetID: budget.id, categoryID: id, category: value, token: liveToken!)
            if existing?.delegatedUserID != delegatedUserID { _ = try await client.updateCategoryDelegation(budgetID: budget.id, categoryID: id, delegatedUserID: delegatedUserID, token: liveToken!) }
        }
        await refresh()
    }
    func updateGroup(id: String, value: APICategoryGroupUpdate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let current = groups.first(where: { $0.id == id }) {
            for index in demoSource.demo.categories.indices where demoSource.demo.categories[index].group == current.name { demoSource.demo.categories[index].group = value.name }
            if let index = demoSource.demo.groupOrder.firstIndex(of: current.name) { demoSource.demo.groupOrder[index] = value.name; demoSource.demo.groupOrder.remove(at: index); demoSource.demo.groupOrder.insert(value.name, at: min(max(value.sortOrder, 0), demoSource.demo.groupOrder.count)) }
            demoSource.demo.archivedGroups.remove(current.name); if value.isArchived { demoSource.demo.archivedGroups.insert(value.name) }
        } else { _ = try await liveClient().updateCategoryGroup(budgetID: budget.id, groupID: id, group: value, token: liveToken!) }
        await refresh()
    }
    func deleteGroup(id: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let current = groups.first(where: { $0.id == id }) { guard !demoSource.demo.categories.contains(where: { $0.group == current.name }) else { throw workspaceError("Move or archive every category before deleting this group") }; demoSource.demo.groupOrder.removeAll { $0 == current.name } }
        else { try await liveClient().deleteCategoryGroup(budgetID: budget.id, groupID: id, token: liveToken!) }
        await refresh()
    }
    func deleteCategory(id: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource { guard !demoSource.demo.transactions.contains(where: { $0.categoryIDs.contains(id) }) else { throw workspaceError("This category has financial history. Archive it to preserve the audit trail") }; demoSource.demo.categories.removeAll { $0.id == id } }
        else { try await liveClient().deleteCategory(budgetID: budget.id, categoryID: id, token: liveToken!) }
        await refresh()
    }

    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let index = demoSource.demo.categories.firstIndex(where: { $0.id == categoryID }) {
            demoSource.demo.categories[index].target = value.targetAmountMinor
            demoSource.demo.categories[index].targetDate = value.targetDate
            demoSource.demo.categories[index].targetType = value.targetType
            demoSource.demo.categories[index].targetRecurrenceMonths = value.recurrenceMonths
            demoSource.demo.categories[index].targetMinimumContribution = value.minimumContributionMinor
            demoSource.demo.categories[index].targetPriority = value.priority
            demoSource.demo.categories[index].targetIsActive = value.isActive
        }
        else { _ = try await liveClient().upsertCategoryTarget(budgetID: budget.id, categoryID: categoryID, target: value, token: liveToken!) }
        await refresh()
    }
    func deleteTarget(categoryID: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let index = demoSource.demo.categories.firstIndex(where: { $0.id == categoryID }) { demoSource.demo.categories[index].target = nil; demoSource.demo.categories[index].targetDate = nil; demoSource.demo.categories[index].targetType = "savings_balance"; demoSource.demo.categories[index].targetRecurrenceMonths = nil; demoSource.demo.categories[index].targetMinimumContribution = 0; demoSource.demo.categories[index].targetPriority = 50; demoSource.demo.categories[index].targetIsActive = true }
        else { try await liveClient().deleteCategoryTarget(budgetID: budget.id, categoryID: categoryID, token: liveToken!) }
        await refresh()
    }

    func createSchedule(_ value: APIScheduledTransactionCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            demoSource.demo.schedules.append(.init(id: UUID().uuidString, accountID: value.accountID, destinationAccountID: value.destinationAccountID, categoryID: value.categoryID, name: value.name, amount: value.amountMinor, nextDate: value.nextDate, recurrenceUnit: value.recurrenceUnit, intervalCount: value.intervalCount, memo: value.memo, isActive: value.isActive))
        } else { _ = try await liveClient().createScheduledTransaction(budgetID: budget.id, schedule: value, token: liveToken!) }
        await refresh()
    }

    func updateSchedule(id: String, value: APIScheduledTransactionCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let index = demoSource.demo.schedules.firstIndex(where: { $0.id == id }) {
            demoSource.demo.schedules[index].accountID = value.accountID
            demoSource.demo.schedules[index].destinationAccountID = value.destinationAccountID
            demoSource.demo.schedules[index].categoryID = value.categoryID
            demoSource.demo.schedules[index].name = value.name
            demoSource.demo.schedules[index].amount = value.amountMinor
            demoSource.demo.schedules[index].nextDate = value.nextDate
            demoSource.demo.schedules[index].recurrenceUnit = value.recurrenceUnit
            demoSource.demo.schedules[index].intervalCount = value.intervalCount
            demoSource.demo.schedules[index].memo = value.memo
            demoSource.demo.schedules[index].isActive = value.isActive
        } else { _ = try await liveClient().updateScheduledTransaction(budgetID: budget.id, scheduleID: id, schedule: value, token: liveToken!) }
        await refresh()
    }

    func deleteSchedule(id: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource { demoSource.demo.schedules.removeAll { $0.id == id } }
        else { try await liveClient().deleteScheduledTransaction(budgetID: budget.id, scheduleID: id, token: liveToken!) }
        await refresh()
    }

    @discardableResult func realizeSchedule(id: String) async throws -> APIScheduledRealization {
        let result: APIScheduledRealization
        if let demoSource = dataSource as? DemoWorkspaceDataSource, let index = demoSource.demo.schedules.firstIndex(where: { $0.id == id }) {
            let item = demoSource.demo.schedules[index]
            guard item.isActive else { throw workspaceError("Scheduled transaction is inactive") }
            let due = Self.parseDate(item.nextDate)
            guard Calendar.current.startOfDay(for: due) <= Calendar.current.startOfDay(for: Date()) else { throw workspaceError("This scheduled transaction is not due yet") }
            let before = Set(demoSource.demo.transactions.map(\.id))
            if let destination = item.destinationAccountID {
                guard demoSource.demo.transfer(amount: item.amount, from: item.accountID, to: destination, memo: item.memo, cleared: false, date: due) else { throw workspaceError(demoSource.demo.errorMessage) }
            } else {
                demoSource.demo.createTransaction(payee: item.name, signedAmount: item.amount, date: due, accountID: item.accountID, categoryAmounts: item.categoryID.map { [$0: item.amount] } ?? [:], memo: item.memo, cleared: false)
            }
            let transactionIDs = demoSource.demo.transactions.map(\.id).filter { !before.contains($0) }
            let next = Self.nextScheduledDate(from: due, unit: item.recurrenceUnit, interval: item.intervalCount)
            demoSource.demo.schedules[index].lastRealizedOn = item.nextDate
            demoSource.demo.schedules[index].isActive = next != nil
            if let next { demoSource.demo.schedules[index].nextDate = Self.dateString(next) }
            let body: [String: Any] = ["scheduled_transaction_id": id, "transaction_ids": transactionIDs, "realized_on": item.nextDate, "next_date": next.map(Self.dateString) ?? NSNull(), "is_active": next != nil, "last_realized_on": item.nextDate]
            result = try JSONDecoder().decode(APIScheduledRealization.self, from: JSONSerialization.data(withJSONObject: body))
        } else { result = try await liveClient().realizeScheduledTransaction(budgetID: budget.id, scheduleID: id, token: liveToken!) }
        await refresh()
        return result
    }

    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            if decision == "approve", let amount { demoSource.demo.approve(id, amount: amount) }
            else if let index = demoSource.demo.requests.firstIndex(where: { $0.id == id }) { demoSource.demo.requests[index].status = decision == "reject" ? "Rejected" : "Changes requested" }
        } else { _ = try await liveClient().decideFinancialRequest(budgetID: budget.id, requestID: id, decision: APIFinancialRequestDecision(decision: decision, expectedRequestVersion: version, approvedAmountMinor: amount, sourceCategoryID: sourceCategoryID, note: note), token: liveToken!) }
        await refresh()
    }

    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            var remaining = max(demoSource.demo.readyToAssign, 0)
            var rows: [[String: Any]] = []
            for category in demoSource.demo.visibleCategories where remaining > 0 {
                let needed = max((category.target ?? 0) - category.available, 0); let amount = min(needed, remaining)
                if amount > 0 { rows.append(["category_id": category.id, "category_name": category.name, "amount_minor": amount, "before_available_minor": category.available, "after_available_minor": category.available + amount]); remaining -= amount }
            }
            let proposed = max(demoSource.demo.readyToAssign, 0) - remaining
            let json: [String: Any] = ["month": month, "currency_code": "USD", "before_ready_to_assign_minor": demoSource.demo.readyToAssign, "proposed_minor": proposed, "after_ready_to_assign_minor": demoSource.demo.readyToAssign - proposed, "allocation_version": 1, "proposals": rows]
            return try JSONDecoder().decode(APISmartFundingPreview.self, from: JSONSerialization.data(withJSONObject: json))
        }
        return try await liveClient().smartFundingPreview(budgetID: budget.id, month: month, token: liveToken!)
    }

    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource {
            for proposal in preview.proposals { demoSource.demo.assign(amount: proposal.amountMinor, to: proposal.categoryID) }
        } else { _ = try await liveClient().commitSmartFunding(budgetID: budget.id, month: preview.month, expectedAllocationVersion: preview.allocationVersion, token: liveToken!) }
        await refresh()
    }

    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws {
        guard dataSource == nil else { throw workspaceError("Owner policy editing is demonstrated in live mode; use a delegated demo persona to verify the member experience.") }
        _ = try await liveClient().updateDelegatedBudget(budgetID: budget.id, userID: userID, policy: value, token: liveToken!)
        await refresh()
    }

    private func liveClient() throws -> APIClient {
        guard let liveServerURL, liveToken != nil else { throw workspaceError("Live server session is unavailable.") }
        return try APIClient(baseURL: liveServerURL)
    }
    private func workspaceError(_ message: String?) -> NSError { NSError(domain: "BudgetWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "Unable to complete the change."]) }

    func format(_ minor: Int64) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = budget.currencyCode
        let divisor = pow(10.0, Double(formatter.maximumFractionDigits))
        return formatter.string(from: NSNumber(value: Double(minor) / divisor)) ?? "\(minor)"
    }

    // Plain-language, server-authoritative overspend explanation: cash overspending "needs
    // coverage" from other money; unfunded card spending "became card debt".
    func overspendSummary(_ row: APICategoryMonth) -> String? {
        guard row.isOverspent else { return nil }
        let cash = row.cashOverspentMinor ?? 0
        let credit = row.creditOverspentMinor ?? 0
        if credit > 0 && cash > 0 { return "\(format(cash)) needs coverage · \(format(credit)) became card debt" }
        if credit > 0 { return "\(format(credit)) became card debt" }
        return "\(format(cash > 0 ? cash : -row.availableMinor)) needs coverage"
    }

    func categoryName(_ transaction: APITransaction) -> String {
        let ids = transaction.categoryID.map { [$0] } ?? transaction.splits.map(\.categoryID)
        return ids.compactMap { id in categories.first(where: { $0.id == id })?.name }.joined(separator: ", ")
    }

    func balance(for account: APIAccount) -> Int64 {
        accountBalances[account.id]?.workingBalanceMinor ?? transactions.filter { $0.accountID == account.id }.reduce(0) { $0 + $1.amountMinor }
    }
    func clearedBalance(for account: APIAccount) -> Int64 { accountBalances[account.id]?.clearedBalanceMinor ?? transactions.filter { $0.accountID == account.id && $0.isCleared }.reduce(0) { $0 + $1.amountMinor } }
    func unclearedBalance(for account: APIAccount) -> Int64 { accountBalances[account.id]?.unclearedBalanceMinor ?? transactions.filter { $0.accountID == account.id && !$0.isCleared }.reduce(0) { $0 + $1.amountMinor } }
    func transactions(for account: APIAccount) -> [APITransaction] {
        transactions.filter { $0.accountID == account.id }.sorted {
            if $0.occurredOn == $1.occurredOn { return $0.id > $1.id }
            return $0.occurredOn > $1.occurredOn
        }
    }

    func reportRange(calendar: Calendar = .current, now: Date = Date()) -> (Date, Date) {
        let effectiveNow = dataSource == nil ? now : Date.demo(monthsAgo: 0, day: 30)
        let end = calendar.startOfDay(for: reportPeriod == "custom" ? customReportEnd : effectiveNow)
        let start: Date
        switch reportPeriod {
        case "60d": start = calendar.date(byAdding: .day, value: -59, to: end)!
        case "90d": start = calendar.date(byAdding: .day, value: -89, to: end)!
        case "3m": start = calendar.date(byAdding: .month, value: -3, to: calendar.date(byAdding: .day, value: 1, to: end)!)!
        case "6m": start = calendar.date(byAdding: .month, value: -6, to: calendar.date(byAdding: .day, value: 1, to: end)!)!
        case "ytd": start = calendar.date(from: calendar.dateComponents([.year], from: end))!
        case "1y": start = calendar.date(byAdding: .day, value: -364, to: end)!
        case "custom": start = calendar.startOfDay(for: min(customReportStart, customReportEnd))
        default: start = calendar.date(byAdding: .day, value: -29, to: end)!
        }
        return (start, end)
    }

    nonisolated static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func parseDate(_ value: String) -> Date {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) ?? Date()
    }

    nonisolated static func nextScheduledDate(from date: Date, unit: String, interval: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        switch unit {
        case "once": return nil
        case "days": return calendar.date(byAdding: .day, value: interval, to: date)
        case "weeks": return calendar.date(byAdding: .day, value: interval * 7, to: date)
        case "months": return calendar.date(byAdding: .month, value: interval, to: date)
        case "years": return calendar.date(byAdding: .year, value: interval, to: date)
        default: return nil
        }
    }
}

struct BudgetWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var store: BudgetWorkspaceStore
    @State private var showingSettings = false
    @State private var selectedTab: Int
    private let canDismiss: Bool
    private let selectionOverride: Binding<Int>?

    init(budget: APIBudget, canDismiss: Bool = false) { _store = StateObject(wrappedValue: BudgetWorkspaceStore(budget: budget)); _selectedTab = State(initialValue: 0); self.canDismiss = canDismiss; selectionOverride = nil }
    private init(demo: Bool) { _store = StateObject(wrappedValue: .demo()); let screen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-screen=") }?.split(separator: "=").last.map(String.init) ?? "home"; _selectedTab = State(initialValue: ["home":0,"plan":1,"activity":2,"transaction":2,"accounts":3,"credit":3,"insights":4][screen] ?? 0); canDismiss = ProcessInfo.processInfo.arguments.contains("--workspace-dismiss"); selectionOverride = nil }
    init(testStore: BudgetWorkspaceStore, selection: Binding<Int>, canDismiss: Bool = true) { _store = StateObject(wrappedValue: testStore); _selectedTab = State(initialValue: 0); self.canDismiss = canDismiss; selectionOverride = selection }
    static func demo() -> BudgetWorkspaceView { BudgetWorkspaceView(demo: true) }
    private var tabSelection: Binding<Int> { selectionOverride ?? $selectedTab }
    private var activeTab: Int { selectionOverride?.wrappedValue ?? selectedTab }

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack { LiveHomeView(showSettings: { showingSettings = true }).workspaceDismissToolbar(canDismiss) }.tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack { LivePlanView().workspaceDismissToolbar(canDismiss) }.tabItem { Label("Plan", systemImage: "square.grid.2x2.fill") }.tag(1)
            NavigationStack { LiveActivityView().workspaceDismissToolbar(canDismiss) }.tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { LiveAccountsView().workspaceDismissToolbar(canDismiss) }.tabItem { Label("Accounts", systemImage: "creditcard.fill") }.tag(3)
            NavigationStack { LiveInsightsView().workspaceDismissToolbar(canDismiss) }.tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }.tag(4)
        }
        // iOS 27 can update the selected tab while leaving a previously lazy per-tab NavigationStack
        // unmaterialized. Re-keying only the TabView at selection time forces the selected production
        // navigation root to resolve while preserving every tab's title, toolbar, and navigation path.
        .id(activeTab)
        .tint(Theme.accent)
        .overlay { if store.isLoading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await reload() }
        .alert("Unable to complete request", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Retry") { Task { await reload() } }; Button("Cancel", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "Unknown error") }
        .sheet(isPresented: $showingSettings) {
            WorkspaceProfileView(store: store)
                .environmentObject(session)
                .environmentObject(store)
        }
        // Keep workspace dependencies outside every presentation modifier so
        // sheets and their navigation destinations inherit the same instances.
        .environmentObject(store)
        .environmentObject(session)
    }

    private func reload() async {
        if session.sourceMode == .deterministic {
            await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
            return
        }
        // AppSession/RootView exclusively owns authentication. A reconstructed tab or workspace
        // must never start another refresh cycle after the session generation was invalidated.
        guard let url = session.serverURL, let token = session.token else {
            return
        }
        await store.load(serverURL: url, token: token)
    }
}

private struct WorkspaceProfileView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BudgetWorkspaceStore
    @State private var showHousehold = false
    @State private var showConnection = false
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    LabeledContent("User", value: session.profile?.displayName ?? "Demo household owner")
                    LabeledContent("Active budget", value: store.budget.name)
                }
                if session.sourceMode == .liveServer {
                    Section("Budgets") {
                        ForEach(session.budgets) { budget in
                            Button { session.selectBudget(budget.id); dismiss() } label: {
                                HStack { Text(budget.name); Spacer(); if budget.id == store.budget.id { Image(systemName: "checkmark") } }
                            }
                        }
                        if session.profile?.households.contains(where: { $0.role == "owner" && $0.isActive }) == true {
                            Button("Create another budget", systemImage: "plus") { showCreate = true }
                        }
                    }
                }
                Section("Household") { Button("Household and access", systemImage: "person.3") { showHousehold = true } }
                Section("Connection") {
                    LabeledContent("Source", value: session.sourceMode.title)
                    LabeledContent("Status", value: session.connectionStatus.title)
                    Button("Server and data source", systemImage: "server.rack") { showConnection = true }
                }
                if session.sourceMode == .liveServer {
                    Section { Button("Sign Out", role: .destructive) { session.signOut(); dismiss() } }
                }
            }
            .navigationTitle("Profile & Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showHousehold) { LiveHouseholdView(session: session, store: store) }
            .navigationDestination(isPresented: $showConnection) { ServerConnectionSettingsView() }
            .sheet(isPresented: $showCreate) {
                BudgetCreationView(households: session.profile?.households.filter { $0.role == "owner" && $0.isActive } ?? [])
            }
        }
    }
}

private struct WorkspaceDismissToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let enabled: Bool
    func body(content: Content) -> some View {
        content.toolbar {
            if enabled {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Budgets", systemImage: "chevron.backward") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    func workspaceDismissToolbar(_ enabled: Bool) -> some View {
        modifier(WorkspaceDismissToolbar(enabled: enabled))
    }
}

private struct LiveHomeView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let showSettings: () -> Void
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.delegatedBudget == nil ? "AVAILABLE TO ASSIGN" : "AVAILABLE IN YOUR BUDGET").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(store.format(store.delegatedBudget?.availableToAssignMinor ?? store.summary?.readyToAssignMinor ?? 0)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(store.delegatedBudget == nil ? "Real money waiting for a purpose" : "Delegated money you control but have not categorized").foregroundStyle(.secondary)
                }.padding(.vertical, 10)
            }
            if let summary = store.summary {
                Section("Needs attention") {
                    ForEach(summary.categories.filter(\.isOverspent)) { row in Label("\(row.name): \(store.overspendSummary(row) ?? "")", systemImage: (row.creditOverspentMinor ?? 0) > 0 && (row.cashOverspentMinor ?? 0) == 0 ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
                    ForEach(store.requests.filter { $0.status == "pending" }) { request in NavigationLink { LiveRequestDetailView(requestID: request.id) } label: { Label("Request pending · \(store.format(request.requestedAmountMinor))", systemImage: "hand.raised.fill") } }
                }
            }
            if !store.scheduledTransactions.isEmpty {
                Section("Upcoming") {
                    ForEach(Array(store.scheduledTransactions.filter(\.isActive).sorted { $0.nextDate < $1.nextDate }.prefix(3))) { item in NavigationLink { LiveScheduledTransactionEditor(schedule: item, currencyCode: store.budget.currencyCode) } label: { ScheduledTransactionRow(item: item) } }
                    NavigationLink("View all scheduled transactions") { LiveScheduledTransactionsView() }
                }
            }
            Section("Recent activity") { ForEach(store.transactions.prefix(5)) { LiveTransactionLink(transaction: $0) } }
            if let forecast = store.forecast { Section("90-day forecast") { LabeledContent("Projected total", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest projected", value: store.format(forecast.lowestProjectedTotalMinor)); NavigationLink("View forecast") { LiveForecastView() } } }
        }.navigationTitle(store.budget.name).toolbar { ToolbarItem(placement: .topBarLeading) { Button(action: showSettings) { Image(systemName: "person.crop.circle") }.accessibilityIdentifier("household-profile-button") } }
    }
}

private struct LiveForecastView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { if let forecast = store.forecast { Section { Text("Projected values include schedules but are not spendable until entered.").font(.footnote).foregroundStyle(.secondary) }; Section("Household cash") { LabeledContent("Today", value: store.format(forecast.actualTotalOnBudgetMinor)); LabeledContent("At \(forecast.through)", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest", value: store.format(forecast.lowestProjectedTotalMinor)) }; Section("Accounts") { ForEach(forecast.accounts) { account in VStack(alignment: .leading) { Text(account.name); HStack { Text("Now \(store.format(account.actualBalanceMinor))"); Spacer(); Text("Projected \(store.format(account.projectedBalanceMinor))") }.font(.caption).foregroundStyle(.secondary) } } }; Section("Scheduled activity") { if forecast.occurrences.isEmpty { Text("No scheduled transactions in this period").foregroundStyle(.secondary) }; ForEach(forecast.occurrences) { item in if let schedule = store.scheduledTransactions.first(where: { $0.id == item.scheduledTransactionID }) { NavigationLink { LiveScheduledTransactionEditor(schedule: schedule, currencyCode: store.budget.currencyCode) } label: { HStack { VStack(alignment: .leading) { Text(item.name); Text(item.occurredOn).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(store.format(item.amountMinor)).monospacedDigit() } } } else { HStack { Text(item.name); Spacer(); Text(store.format(item.amountMinor)).monospacedDigit() } } } } } }.navigationTitle("Forecast") }
}

private struct LiveRequestDetailView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let requestID: String
    @State private var amount = ""; @State private var sourceCategoryID = ""; @State private var note = ""; @State private var isSaving = false; @State private var errorMessage: String?
    private var request: APIFinancialRequest? { store.requests.first(where: { $0.id == requestID }) }
    private var sources: [APICategoryMonth] { (store.summary?.categories ?? []).filter { $0.availableMinor > 0 && $0.categoryID != request?.destinationCategoryID } }
    var body: some View {
        Form {
            if let request {
                Section("Request") {
                    LabeledContent("Requester", value: requesterName(request.requesterUserID))
                    LabeledContent("Amount", value: store.format(request.requestedAmountMinor))
                    LabeledContent("Category", value: store.categories.first(where: { $0.id == request.destinationCategoryID })?.name ?? "Category")
                    LabeledContent("Reason", value: request.reason.isEmpty ? "—" : request.reason)
                }
                if store.budget.can("approve_request") && request.status == "pending" {
                    Section("Decision") {
                        Picker("Fund from", selection: $sourceCategoryID) {
                            ForEach(sources) { Text("\($0.name) · \(store.format($0.availableMinor))").tag($0.categoryID) }
                        }
                        CurrencyAmountField("Approved amount", text: $amount, currencyCode: store.budget.currencyCode)
                        TextField("Note", text: $note)
                    }
                    Section {
                        Button("Approve") { Task { await decide("approve") } }.disabled(parsed == nil || sourceCategoryID.isEmpty || isSaving)
                        Button("Request changes") { Task { await decide("changes_requested") } }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        Button("Reject", role: .destructive) { Task { await decide("reject") } }.disabled(isSaving)
                    }
                }
                Section("History") {
                    ForEach(request.actions) { action in
                        VStack(alignment: .leading) {
                            Text(action.action.replacingOccurrences(of: "_", with: " ").capitalized)
                            if !action.note.isEmpty { Text(action.note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Funding Request")
        .onAppear {
            if let request {
                amount = CurrencyText.editable(request.requestedAmountMinor, currencyCode: store.budget.currencyCode)
                sourceCategoryID = sources.first?.categoryID ?? ""
            }
        }
        .alert("Unable to decide request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
    }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: store.budget.currencyCode), value > 0, value <= (request?.requestedAmountMinor ?? 0) else { return nil }; return value }
    private func requesterName(_ id: String) -> String { store.householdMembers.first(where: { $0.userID == id })?.displayName ?? id.capitalized }
    private func decide(_ decision: String) async { guard let request else { return }; isSaving = true; defer { isSaving = false }; do { try await store.decideRequest(id: request.id, decision: decision, version: request.version, amount: decision == "approve" ? parsed : nil, sourceCategoryID: decision == "approve" ? sourceCategoryID : nil, note: note) } catch { errorMessage = error.localizedDescription } }
}

private struct LivePlanView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var editing: APICategoryMonth?
    @State private var showMove = false
    @State private var showCategory = false
    @State private var showSmartFunding = false
    @State private var showRequest = false
    @State private var managing: APICategory?
    @State private var showGroups = false
    @State private var showGroupCreation = false
    @State private var focus = PlanFocus.all
    private var rows: [APICategoryMonth] { (store.summary?.categories ?? []).filter { row in switch focus { case .all: true; case .underfunded: (row.underfundedMinor ?? 0) > 0; case .overspent: row.isOverspent; case .funded: (row.underfundedMinor ?? 0) == 0 && !row.isOverspent; case .available: row.availableMinor > 0 } } }
    // A brand-new Budget has no groups/categories. Surface a discoverable primary action to create
    // the first group/category through the same production workflow used later, so the owner is not
    // left at a dead end. Gated on structural authority (an owner always has it); delegated members
    // manage only their own scoped categories and do not define the household's first plan skeleton.
    private var activation: FreshBudgetActivationState {
        .init(accountCount: store.accounts.count, groupCount: store.groups.count, categoryCount: store.categories.count,
              canManageStructure: store.delegatedBudget == nil && store.budget.can("manage_budget_structure"))
    }
    var body: some View {
        List {
            if let delegated = store.delegatedBudget {
                Section("Your delegated budget") {
                    LabeledContent("Total authority", value: store.format(delegated.authorityMinor))
                    LabeledContent("Assigned", value: store.format(delegated.assignedMinor))
                    LabeledContent("To assign", value: store.format(delegated.availableToAssignMinor))
                    Text("Reallocations conserve your household allocation and follow the limits selected by the owner.").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let summary = store.summary {
                Section("Available to assign") {
                    Text(store.format(summary.readyToAssignMinor)).font(.largeTitle.bold()).monospacedDigit()
                    Text("Money you currently have that has not been given a purpose yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let summary = store.summary, activation.showsNormalPlan {
                Section("Month summary") { LabeledContent("Assigned", value: store.format(summary.totalAssignedMinor)); LabeledContent("Overspent", value: store.format(summary.totalOverspentMinor)); LabeledContent("Monthly plan cost", value: store.format(summary.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) })) }
            }
            if !activation.showsNormalPlan && !store.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.groups.isEmpty ? "Build your first plan" : "Add your first category").font(.headline)
                        Text(activationExplanation)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if activation.canManageStructure {
                            Button {
                                if activation.needsGroup { showGroupCreation = true }
                                else { showCategory = true }
                            } label: {
                                Label(store.groups.isEmpty ? "Create Category Group" : "Add Category", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(activation.needsGroup ? "create-category-group-cta" : "add-category-cta")
                        } else {
                            Text("A household owner can add the plan structure. Your authorized budget areas will appear here when they are shared with you.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if activation.showsNormalPlan {
                Section("Plan") {
                HStack { Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }; Spacer(); Button("Today") { store.planMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year,.month], from: Date()))!; Task { await reload() } }; Text(store.planMonth.formatted(.dateTime.month(.wide).year())).font(.headline); Spacer(); Button { changeMonth(1) } label: { Image(systemName: "chevron.right") } }
                Picker("Focus", selection: $focus) { ForEach(PlanFocus.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            ForEach(store.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in
                let groupRows = rows.filter { row in store.categories.first(where: { $0.id == row.categoryID })?.groupID == group.id }
                if !groupRows.isEmpty { Section(group.name) { ForEach(groupRows) { category in NavigationLink { LivePlanCategoryDetailView(categoryID: category.categoryID, assign: { editing = category }, move: { showMove = true }, manage: { managing = store.categories.first(where: { $0.id == category.categoryID }) }) } label: { PlanCategoryRow(category: category) }.contextMenu { if let model = store.categories.first(where: { $0.id == category.categoryID }), canManage(model) { Button("Manage Category", systemImage: "pencil") { managing = model } } } } } }
            }
        }.accessibilityIdentifier("plan-screen").navigationTitle("Plan").toolbar {
            Menu {
                if store.delegatedBudget == nil && store.budget.can("assign_money") { Button("Smart Funding", systemImage: "sparkles") { showSmartFunding = true } }
                if store.budget.can("manage_budget_structure") || store.budget.can("manage_own_categories") { Button("Add category", systemImage: "folder.badge.plus") { showCategory = true } }
                if store.budget.can("manage_budget_structure") { Button("Manage groups", systemImage: "folder") { showGroups = true } }
                if store.budget.can("move_money") { Button("Move money", systemImage: "arrow.left.arrow.right") { showMove = true } }
                if store.budget.can("request_money") { Button("Request money", systemImage: "hand.raised") { showRequest = true } }
            } label: { Image(systemName: "plus") }
        }
        .sheet(item: $editing) { category in editAssignment(category) }
        .sheet(isPresented: $showMove) { moveMoney }
        .sheet(isPresented: $showCategory) { createCategory }
        .sheet(isPresented: $showSmartFunding) { smartFunding }
        .sheet(isPresented: $showRequest) { FundingRequestView(budget: store.budget, categories: store.categories, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload) }
        .sheet(item: $managing) { category in LiveCategoryEditView(budget: store.budget, category: category, groups: store.groups, members: store.householdMembers, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload) }
        .sheet(isPresented: $showGroups) { LiveGroupManagementView() }
        .sheet(isPresented: $showGroupCreation) { GroupCreationView() }
    }
    private var activationExplanation: String {
        if store.groups.isEmpty { return "Category groups organize the purposes in your plan. Create one first, then add a category for something you spend or save for." }
        return "Categories give money a specific purpose. After you add one, open it and choose Assign money to move Available to Assign into that category."
    }
    @ViewBuilder private func editAssignment(_ category: APICategoryMonth) -> some View {
        if let summary = store.summary {
            AssignmentEditView(budget: store.budget, category: category, month: String(BudgetWorkspaceStore.dateString(store.planMonth).prefix(7)) + "-01", expectedAllocationVersion: summary.allocationVersion, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload)
        }
    }
    @ViewBuilder private var moveMoney: some View {
        if let summary = store.summary {
            AllocationTransferView(budget: store.budget, categories: summary.categories, expectedAllocationVersion: summary.allocationVersion, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload)
        }
    }
    @ViewBuilder private var createCategory: some View {
        CategoryCreationView(
                budget: store.budget,
                groups: store.groups,
                serverURL: session.serverURL ?? URL(string: "http://localhost")!,
                token: session.token ?? "demo",
                onSaved: reload,
                delegatedUserID: store.budget.can("manage_own_categories") && !store.budget.can("manage_budget_structure") ? session.profile?.id : nil
            )
    }
    @ViewBuilder private var smartFunding: some View {
        LiveSmartFundingView(budget: store.budget, month: String(BudgetWorkspaceStore.dateString(store.planMonth).prefix(7)) + "-01", serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload)
    }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
    private func canManage(_ category: APICategory) -> Bool { store.budget.can("manage_budget_structure") || (store.budget.can("manage_own_categories") && category.delegatedUserID == session.profile?.id) }
    private func changeMonth(_ value: Int) { if let next = Calendar.current.date(byAdding: .month, value: value, to: store.planMonth) { store.planMonth = next; Task { await reload() } } }
}

private struct GroupCreationView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                Text("Groups keep related categories together, such as Monthly Bills or Savings Goals.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("New Category Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if saving { ProgressView() } }
            .alert("Unable to create group", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "Unknown error") }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await store.createGroup(name: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct LiveGroupManagementView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: APICategoryGroup?
    var body: some View { NavigationStack { List { ForEach(store.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in Button { editing=group } label: { HStack { VStack(alignment:.leading){Text(group.name);Text(group.isArchived ? "Hidden" : "Visible").font(.caption).foregroundStyle(.secondary)};Spacer();Text("Order \(group.sortOrder)").foregroundStyle(.secondary) } } } }.navigationTitle("Category Groups").toolbar { ToolbarItem(placement:.confirmationAction){Button("Done"){dismiss()}} }.sheet(item:$editing){LiveGroupEditor(group:$0)} } }
}

private struct LiveGroupEditor: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore; @Environment(\.dismiss) private var dismiss
    let group: APICategoryGroup
    @State private var name: String; @State private var order: Int; @State private var archived: Bool; @State private var saving=false; @State private var error:String?; @State private var confirmDelete=false
    init(group: APICategoryGroup){self.group=group;_name=State(initialValue:group.name);_order=State(initialValue:group.sortOrder);_archived=State(initialValue:group.isArchived)}
    var body: some View { NavigationStack { Form { TextField("Name",text:$name);Stepper("Order \(order)",value:$order,in:0...10_000);Toggle("Hidden",isOn:$archived);Section{Text("Hiding a group preserves every category and its financial history.").font(.footnote).foregroundStyle(.secondary)};Section{Button("Delete Empty Group",role:.destructive){confirmDelete=true}} }.navigationTitle("Manage Group").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || saving)}}.confirmationDialog("Delete this group?",isPresented:$confirmDelete){Button("Delete Empty Group",role:.destructive){Task{await remove()}}} .alert("Unable to update group",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("OK",role:.cancel){}}message:{Text(error ?? "Unknown error")} } }
    private func save()async{saving=true;defer{saving=false};do{try await store.updateGroup(id:group.id,value:APICategoryGroupUpdate(name:name,sortOrder:order,isArchived:archived));dismiss()}catch{self.error=error.localizedDescription}}
    private func remove()async{saving=true;defer{saving=false};do{try await store.deleteGroup(id:group.id);dismiss()}catch{self.error=error.localizedDescription}}
}

private enum PlanFocus: String, CaseIterable, Identifiable { case all = "All", underfunded = "Underfunded", overspent = "Overspent", funded = "Funded", available = "Available"; var id: Self { self } }

private struct PlanCategoryRow: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let category: APICategoryMonth
    var body: some View { VStack(alignment: .leading, spacing: 5) { HStack { Text(category.name); Spacer(); Text(store.format(category.availableMinor)).fontWeight(.semibold).foregroundStyle(category.isOverspent ? Theme.danger : .primary) }; HStack { Text("Assigned \(store.format(category.assignedMinor))"); Spacer(); Text("Activity \(store.format(category.activityMinor))") }.font(.caption).foregroundStyle(.secondary); if let overspend = store.overspendSummary(category) { Label(overspend, systemImage: (category.creditOverspentMinor ?? 0) > 0 ? "creditcard.trianglebadge.exclamationmark" : "banknote").font(.caption).foregroundStyle(Theme.danger).accessibilityLabel(overspend) } else if let funded = category.fundedCreditSpendingMinor, funded > 0 { Label("\(store.format(funded)) reserved for card payment", systemImage: "creditcard.and.123").font(.caption).foregroundStyle(Theme.healthy) }; if category.targetType != nil { ProgressView(value: targetProgress).accessibilityLabel("Target progress").accessibilityValue(targetProgress.formatted(.percent)); HStack { Label(status, systemImage: (category.underfundedMinor ?? 0) > 0 ? "target" : "checkmark.circle.fill"); Spacer(); if let needed = category.underfundedMinor, needed > 0 { Text("\(store.format(needed)) needed") } }.font(.caption).foregroundStyle((category.underfundedMinor ?? 0) > 0 ? Theme.attention : Theme.healthy) } } }
    private var targetProgress: Double { let recommendation = category.recommendedContributionMinor ?? 0; guard recommendation > 0 else { return 1 }; return min(Double(max(recommendation - (category.underfundedMinor ?? 0), 0)) / Double(recommendation), 1) }
    private var status: String { category.isOverspent ? "Overspent" : (category.underfundedMinor ?? 0) > 0 ? "Underfunded" : category.targetType == nil ? "Available" : "Funded" }
}

private struct LivePlanCategoryDetailView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let categoryID: String
    let assign: () -> Void
    let move: () -> Void
    let manage: () -> Void
    @State private var showTarget = false
    private var row: APICategoryMonth? { store.summary?.categories.first { $0.categoryID == categoryID } }
    private var model: APICategory? { store.categories.first { $0.id == categoryID } }
    private var transactions: [APITransaction] { store.transactions.filter { $0.categoryID == categoryID || $0.splits.contains(where: { $0.categoryID == categoryID }) } }
    private var operations: [(APIAllocationOperation, APIAllocationPosting)] { store.allocationOperations.flatMap { operation in operation.postings.filter { $0.categoryID == categoryID }.map { (operation, $0) } } }
    var body: some View { List { if let row { Section("Plan") { LabeledContent("Available", value: store.format(row.availableMinor)); LabeledContent("Assigned this month", value: store.format(row.assignedMinor)); LabeledContent("Activity this month", value: store.format(row.activityMinor)); LabeledContent("Rollover into month", value: store.format(row.carriedAvailableMinor)); if row.targetType != nil { LabeledContent("Target recommendation", value: store.format(row.recommendedContributionMinor ?? 0)); LabeledContent("Still needed", value: store.format(row.underfundedMinor ?? 0)); if let date = row.targetDate { LabeledContent("Due", value: date) } }; if let overspend = store.overspendSummary(row) { VStack(alignment: .leading, spacing: 2) { Label(overspend, systemImage: (row.creditOverspentMinor ?? 0) > 0 && (row.cashOverspentMinor ?? 0) == 0 ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill").foregroundStyle(Theme.danger); Text((row.creditOverspentMinor ?? 0) > 0 ? "Unfunded card spending adds to card debt; fund the card payment category to cover it." : "Move available money here or reduce spending to cover the shortfall.").font(.caption).foregroundStyle(.secondary) } } }; Section("Actions") { if store.budget.can("assign_money") { Button("Assign money", action: assign) }; if store.budget.can("move_money") { Button("Move money", action: move) }; if store.budget.can("manage_planning") { Button(store.targets[categoryID] == nil ? "Create target" : "Manage target") { showTarget = true } }; if model != nil { Button("Edit category", action: manage) } } }; let schedules = store.scheduledTransactions.filter { $0.isActive && $0.categoryID == categoryID }; if !schedules.isEmpty { Section("Upcoming scheduled") { ForEach(schedules) { item in NavigationLink { LiveScheduledTransactionEditor(schedule: item, currencyCode: store.budget.currencyCode) } label: { ScheduledTransactionRow(item: item) } } } }; Section("Recent activity") { if transactions.isEmpty { Text("No contributing transactions").foregroundStyle(.secondary) }; ForEach(transactions.prefix(20)) { LiveTransactionLink(transaction: $0) } }; Section("Allocation history") { if operations.isEmpty { Text("No allocation movements available").foregroundStyle(.secondary) }; ForEach(Array(operations.enumerated()), id: \.offset) { _, value in VStack(alignment: .leading) { Text(value.0.note.isEmpty ? value.0.kind.replacingOccurrences(of: "_", with: " ").capitalized : value.0.note); HStack { Text(value.0.occurredOn); Spacer(); Text(store.format(value.1.amountMinor)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary) } } } }.navigationTitle(row?.name ?? "Category").sheet(isPresented: $showTarget) { LiveTargetEditor(categoryID: categoryID, categoryName: row?.name ?? "Category", currencyCode: store.budget.currencyCode, existing: store.targets[categoryID]) } }
}

private struct LiveTargetEditor: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let categoryID: String; let categoryName: String; let currencyCode: String; let existing: APICategoryTarget?
    @State private var type: String; @State private var amount: String; @State private var dueDate: Date; @State private var recurrence: Int; @State private var minimum: String; @State private var priority: Int; @State private var active: Bool; @State private var saving = false; @State private var error: String?; @State private var confirmDelete = false
    init(categoryID: String, categoryName: String, currencyCode: String, existing: APICategoryTarget?) { self.categoryID=categoryID;self.categoryName=categoryName;self.currencyCode=currencyCode;self.existing=existing;_type=State(initialValue:existing?.targetType ?? "monthly_funding");_amount=State(initialValue:CurrencyText.editable(existing?.targetAmountMinor ?? 0,currencyCode:currencyCode));_dueDate=State(initialValue:existing?.targetDate.flatMap(BudgetWorkspaceStore.parseDate) ?? Date());_recurrence=State(initialValue:existing?.recurrenceMonths ?? 1);_minimum=State(initialValue:CurrencyText.editable(existing?.minimumContributionMinor ?? 0,currencyCode:currencyCode));_priority=State(initialValue:existing?.priority ?? 50);_active=State(initialValue:existing?.isActive ?? true) }
    private var dated: Bool { type == "target_by_date" || type == "recurring_expense" }
    private var parsed: Int64? { guard let value=CurrencyText.parseMinorUnits(amount,currencyCode:store.budget.currencyCode),value>0 else{return nil};return value }
    private var parsedMinimum: Int64? { guard let value=CurrencyText.parseMinorUnits(minimum,currencyCode:store.budget.currencyCode),value>=0 else{return nil};return value }
    var body: some View { NavigationStack { Form { Section(categoryName) { Picker("Target type",selection:$type){Text("Monthly funding").tag("monthly_funding");Text("Savings balance").tag("savings_balance");Text("By date").tag("target_by_date");Text("Recurring expense").tag("recurring_expense")};CurrencyAmountField("Target amount",text:$amount,currencyCode:store.budget.currencyCode);CurrencyAmountField("Minimum contribution",text:$minimum,currencyCode:store.budget.currencyCode,allowsZero:true);if dated{DatePicker("Due date",selection:$dueDate,displayedComponents:.date)};if type=="recurring_expense"{Stepper("Every \(recurrence) month\(recurrence == 1 ? "" : "s")",value:$recurrence,in:1...1200);Button("Set annual cadence"){recurrence=12}};Stepper("Priority \(priority)",value:$priority,in:0...100);Toggle("Target active",isOn:$active)};Section{Text("Targets guide planning only. Saving this target does not move money, change account balances, or increase Ready to Assign.").font(.footnote).foregroundStyle(.secondary)};if existing != nil{Section{Button("Delete Target",role:.destructive){confirmDelete=true}}} }.navigationTitle(existing == nil ? "New Target" : "Edit Target").navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(parsed==nil || parsedMinimum==nil || saving)}}.confirmationDialog("Delete this target?",isPresented:$confirmDelete){Button("Delete Target",role:.destructive){Task{await remove()}}}.alert("Unable to save target",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("OK",role:.cancel){}}message:{Text(error ?? "Unknown error")} } }
    private func save() async { guard let parsed,let parsedMinimum else{return};saving=true;defer{saving=false};do{try await store.saveTarget(categoryID:categoryID,value:APICategoryTargetUpsert(targetType:type,targetAmountMinor:parsed,targetDate:dated ? BudgetWorkspaceStore.dateString(dueDate):nil,recurrenceMonths:type == "recurring_expense" ? recurrence:nil,minimumContributionMinor:parsedMinimum,priority:priority,isActive:active));dismiss()}catch{self.error=error.localizedDescription} }
    private func remove() async { saving=true;defer{saving=false};do{try await store.deleteTarget(categoryID:categoryID);dismiss()}catch{self.error=error.localizedDescription} }
}

private struct LiveSmartFundingView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let month: String; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: APISmartFundingPreview?; @State private var isLoading = false; @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            List {
                if let preview {
                    Section("Preview — nothing moves yet") {
                        LabeledContent("Before", value: currency(preview.beforeReadyToAssignMinor))
                        LabeledContent("Proposed", value: currency(-preview.proposedMinor))
                        LabeledContent("After", value: currency(preview.afterReadyToAssignMinor))
                    }
                    Section("Target recommendations") { ForEach(preview.proposals) { proposal in LabeledContent(proposal.categoryName, value: currency(proposal.amountMinor)) } }
                } else if !isLoading { ContentUnavailableView("No funding preview", systemImage: "sparkles") }
            }.navigationTitle("Smart Funding").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Confirm"){Task{await commit()}}.disabled(preview?.proposals.isEmpty != false || isLoading)} }
                .overlay { if isLoading { ProgressView() } }.task { await load() }
                .alert("Unable to fund plan",isPresented:Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})){Button("OK",role:.cancel){}}message:{Text(errorMessage ?? "Unknown error")}
        }
    }
    private func currency(_ minor:Int64)->String{let f=NumberFormatter();f.numberStyle = .currency;f.currencyCode=budget.currencyCode;return f.string(from:NSNumber(value:Double(minor)/pow(10,Double(f.maximumFractionDigits)))) ?? "\(minor)"}
    private func load() async { isLoading=true;defer{isLoading=false};do{preview=try await workspace.smartFundingPreview(month:month)}catch{errorMessage=error.localizedDescription} }
    private func commit() async { guard let preview else{return};isLoading=true;defer{isLoading=false};do{try await workspace.commitSmartFunding(preview);dismiss()}catch{errorMessage=error.localizedDescription} }
}

private struct LiveActivityView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var search = ""
    @State private var showAdd = false
    @State private var showTransfer = false
    var filtered: [APITransaction] { store.transactions.filter { search.isEmpty || $0.payeeName.localizedCaseInsensitiveContains(search) || $0.memo.localizedCaseInsensitiveContains(search) || store.categoryName($0).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            Section("Planning") { NavigationLink { LiveScheduledTransactionsView() } label: { Label("Scheduled transactions", systemImage: "calendar.badge.clock") } }
            Section("Posted activity") { ForEach(filtered) { LiveTransactionLink(transaction: $0) } }
        }
            .searchable(text: $search, prompt: "Payee, memo, or category")
            .navigationTitle("Activity")
            .toolbar { if store.budget.can("create_transaction") { Menu { Button("Transaction", systemImage: "cart") { showAdd = true }; Button("Transfer", systemImage: "arrow.left.arrow.right") { showTransfer = true } } label: { Image(systemName: "plus") } } }
            .sheet(isPresented: $showAdd) { entry }
            .sheet(isPresented: $showTransfer) { transfer }
    }
    @ViewBuilder private var transfer: some View {
        LiveTransferView(budget: store.budget, accounts: store.accounts, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload)
    }
    @ViewBuilder private var entry: some View {
        TransactionEntryView(budget: store.budget, accounts: store.accounts, categories: store.categories, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload)
    }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
}

private enum ScheduledKind: String, CaseIterable, Identifiable {
    case expense = "Expense", income = "Income", transfer = "Transfer"
    var id: Self { self }
    var symbol: String { switch self { case .expense: "arrow.up.right"; case .income: "arrow.down.left"; case .transfer: "arrow.left.arrow.right" } }
}

private struct LiveScheduledTransactionsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showCreate = false
    private var due: [APIScheduledTransaction] { store.scheduledTransactions.filter { $0.isActive && BudgetWorkspaceStore.parseDate($0.nextDate) <= Date() }.sorted { $0.nextDate < $1.nextDate } }
    private var upcoming: [APIScheduledTransaction] { store.scheduledTransactions.filter { $0.isActive && BudgetWorkspaceStore.parseDate($0.nextDate) > Date() }.sorted { $0.nextDate < $1.nextDate } }
    private var paused: [APIScheduledTransaction] { store.scheduledTransactions.filter { !$0.isActive }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var body: some View {
        List {
            Section { Text("Scheduled money is a forecast only. It changes no balance, category, or Available amount until you explicitly enter it.").font(.footnote).foregroundStyle(.secondary) }
            if store.scheduledTransactions.isEmpty && !store.isLoading { ContentUnavailableView("No scheduled transactions", systemImage: "calendar.badge.plus", description: Text("Add recurring bills, income, or transfers without posting them early.")) }
            scheduleSection("Due", values: due)
            scheduleSection("Upcoming", values: upcoming)
            scheduleSection("Paused", values: paused)
        }
        .navigationTitle("Scheduled")
        .toolbar { if store.budget.can("manage_planning") { Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add scheduled transaction") } }
        .sheet(isPresented: $showCreate) { LiveScheduledTransactionEditor(schedule: nil, currencyCode: store.budget.currencyCode) }
        .refreshable { await store.refresh() }
    }
    @ViewBuilder private func scheduleSection(_ title: String, values: [APIScheduledTransaction]) -> some View {
        if !values.isEmpty { Section(title) { ForEach(values) { item in NavigationLink { LiveScheduledTransactionEditor(schedule: item, currencyCode: store.budget.currencyCode) } label: { ScheduledTransactionRow(item: item) } } } }
    }
}

private struct ScheduledTransactionRow: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let item: APIScheduledTransaction
    private var kind: ScheduledKind { item.destinationAccountID != nil ? .transfer : item.amountMinor > 0 ? .income : .expense }
    private var recurrence: String { item.recurrenceUnit == "once" ? "Once" : "Every \(item.intervalCount == 1 ? "" : "\(item.intervalCount) ")\(item.recurrenceUnit.dropLast(item.intervalCount == 1 ? 1 : 0))" }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).frame(width: 28, height: 28).foregroundStyle(kind == .income ? Theme.healthy : kind == .transfer ? Theme.projected : Theme.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).fontWeight(.medium)
                Text(item.isActive ? "\(accountName(item.accountID)) · \(recurrence)" : "Paused · no forecast or realization").font(.caption).foregroundStyle(item.isActive ? .secondary : Theme.attention)
                if let category = item.categoryID { Text(store.categories.first(where: { $0.id == category })?.name ?? "Category").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) { Text(store.format(item.amountMinor)).monospacedDigit(); Text(item.nextDate).font(.caption).foregroundStyle(BudgetWorkspaceStore.parseDate(item.nextDate) <= Date() ? Theme.danger : .secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.isActive ? "active" : "paused"), \(kind.rawValue), \(store.format(item.amountMinor)), \(recurrence), next \(item.nextDate)")
    }
    private func accountName(_ id: String) -> String { store.accounts.first(where: { $0.id == id })?.name ?? "Account" }
}

private struct LiveScheduledTransactionEditor: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let schedule: APIScheduledTransaction?
    let currencyCode: String
    @State private var kind: ScheduledKind
    @State private var accountID: String
    @State private var destinationAccountID: String
    @State private var categoryID: String
    @State private var name: String
    @State private var amount: String
    @State private var nextDate: Date
    @State private var recurrenceUnit: String
    @State private var intervalCount: Int
    @State private var memo: String
    @State private var active: Bool
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var confirmRealize = false

    init(schedule: APIScheduledTransaction?, currencyCode: String) {
        self.schedule = schedule; self.currencyCode = currencyCode
        let inferred: ScheduledKind = schedule?.destinationAccountID != nil ? .transfer : (schedule?.amountMinor ?? -1) > 0 ? .income : .expense
        _kind = State(initialValue: inferred); _accountID = State(initialValue: schedule?.accountID ?? ""); _destinationAccountID = State(initialValue: schedule?.destinationAccountID ?? ""); _categoryID = State(initialValue: schedule?.categoryID ?? ""); _name = State(initialValue: schedule?.name ?? ""); _amount = State(initialValue: CurrencyText.editable(abs(schedule?.amountMinor ?? 0), currencyCode: currencyCode)); _nextDate = State(initialValue: schedule.map { BudgetWorkspaceStore.parseDate($0.nextDate) } ?? Date()); _recurrenceUnit = State(initialValue: schedule?.recurrenceUnit ?? "months"); _intervalCount = State(initialValue: schedule?.intervalCount ?? 1); _memo = State(initialValue: schedule?.memo ?? ""); _active = State(initialValue: schedule?.isActive ?? true)
    }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: store.budget.currencyCode), value > 0 else { return nil }; return value }
    private var due: Bool { schedule?.isActive == true && Calendar.current.startOfDay(for: nextDate) <= Calendar.current.startOfDay(for: Date()) }
    private var valid: Bool { parsed != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !accountID.isEmpty && (kind != .expense || !categoryID.isEmpty) && (kind != .transfer || !destinationAccountID.isEmpty && destinationAccountID != accountID) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    Picker("Type", selection: $kind) { ForEach(ScheduledKind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) } }.onChange(of: kind) { _, value in if value == .transfer { categoryID = "" } else { destinationAccountID = "" } }
                    TextField("Payee or description", text: $name)
                    Picker("Account", selection: $accountID) { Text("Select account").tag(""); ForEach(store.accounts.filter { !$0.isClosed }) { Text($0.name).tag($0.id) } }
                    if kind == .transfer { Picker("Destination", selection: $destinationAccountID) { Text("Select account").tag(""); ForEach(store.accounts.filter { !$0.isClosed && $0.id != accountID }) { Text($0.name).tag($0.id) } } }
                    else if kind == .expense { Picker("Category", selection: $categoryID) { Text("Select category").tag(""); ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } } }
                    CurrencyAmountField("Amount", text: $amount, currencyCode: store.budget.currencyCode)
                    TextField("Memo", text: $memo, axis: .vertical)
                }
                Section("Schedule") {
                    DatePicker("Next occurrence", selection: $nextDate, displayedComponents: .date)
                    Picker("Repeats", selection: $recurrenceUnit) { Text("Once").tag("once"); Text("Days").tag("days"); Text("Weeks").tag("weeks"); Text("Months").tag("months"); Text("Years").tag("years") }
                    if recurrenceUnit != "once" { Stepper("Every \(intervalCount) \(recurrenceUnit)", value: $intervalCount, in: 1...365) }
                    Toggle("Active", isOn: $active)
                    if kind == .income { Label("Future income remains forecast-only and is not available to spend until entered.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                }
                if let schedule {
                    if due && store.budget.can("create_transaction") { Section { Button("Enter Now", systemImage: "checkmark.circle") { confirmRealize = true }.disabled(saving); Text("This posts the due occurrence through the normal transaction engine and then advances the schedule.").font(.footnote).foregroundStyle(.secondary) } }
                    if store.budget.can("manage_planning") { Section { Button("Delete Schedule", role: .destructive) { confirmDelete = true }; Text("Deleting the schedule keeps any transactions already entered from it.").font(.footnote).foregroundStyle(.secondary) } }
                    if schedule.lastRealizedOn != nil { Section("History") { LabeledContent("Last entered", value: schedule.lastRealizedOn ?? "") } }
                }
            }
            .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; if store.budget.can("manage_planning") { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!valid || saving) } } }
            .confirmationDialog("Enter this occurrence now?", isPresented: $confirmRealize) { Button("Enter Now") { Task { await realize() } } } message: { Text("This creates an actual transaction. It is no longer forecast-only.") }
            .confirmationDialog("Delete this schedule?", isPresented: $confirmDelete) { Button("Delete Schedule", role: .destructive) { Task { await remove() } } }
            .alert("Unable to update schedule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "Unknown error") }
        }
    }
    private func payload(isActive: Bool? = nil) -> APIScheduledTransactionCreate { .init(accountID: accountID, destinationAccountID: kind == .transfer ? destinationAccountID : nil, categoryID: kind == .expense ? categoryID : nil, name: name.trimmingCharacters(in: .whitespacesAndNewlines), amountMinor: kind == .expense ? -(parsed ?? 0) : parsed ?? 0, nextDate: BudgetWorkspaceStore.dateString(nextDate), recurrenceUnit: recurrenceUnit, intervalCount: recurrenceUnit == "once" ? 1 : intervalCount, memo: memo, isActive: isActive ?? active) }
    private func save() async { saving = true; defer { saving = false }; do { if let schedule { try await store.updateSchedule(id: schedule.id, value: payload()) } else { try await store.createSchedule(payload()) }; dismiss() } catch { self.error = error.localizedDescription } }
    private func remove() async { guard let schedule else { return }; saving = true; defer { saving = false }; do { try await store.deleteSchedule(id: schedule.id); dismiss() } catch { self.error = error.localizedDescription } }
    private func realize() async { guard let schedule else { return }; saving = true; defer { saving = false }; do { _ = try await store.realizeSchedule(id: schedule.id); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct LiveTransactionLink: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let transaction: APITransaction
    var body: some View {
        NavigationLink { LiveTransactionDetailView(transactionID: transaction.id) } label: {
            HStack { VStack(alignment: .leading) { Text(transaction.payeeName.isEmpty ? "No payee" : transaction.payeeName); Text(store.categoryName(transaction).isEmpty ? transaction.occurredOn : store.categoryName(transaction)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(store.format(transaction.amountMinor)).monospacedDigit() }
        }
    }
}

private struct LiveTransactionDetailView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let transactionID: String
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var isDeleting = false
    var transaction: APITransaction? { store.transactions.first(where: { $0.id == transactionID }) }
    var body: some View {
        List {
            if let transaction {
                Section { Text(store.format(transaction.amountMinor)).font(.largeTitle.bold()).frame(maxWidth: .infinity).padding() }
                Section("Details") { LabeledContent("Payee", value: transaction.payeeName); LabeledContent("Category", value: store.categoryName(transaction)); LabeledContent("Date", value: transaction.occurredOn); LabeledContent("Status", value: transaction.isReconciled ? "Reconciled" : transaction.isCleared ? "Cleared" : "Uncleared"); LabeledContent("Memo", value: transaction.memo.isEmpty ? "—" : transaction.memo) }
            }
        }.navigationTitle("Transaction").toolbar {
            if let transaction, !transaction.isReconciled {
                Menu {
                    if store.budget.can("edit_transaction") { Button("Edit", systemImage: "pencil") { showEdit = true } }
                    if store.budget.can("delete_transaction") { Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
            .sheet(isPresented: $showEdit) { if let transaction { LiveTransactionEditView(budget: store.budget, transaction: transaction, accounts: store.accounts, categories: store.categories, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload) } }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete Transaction", role: .destructive) { Task { await deleteTransaction() } }; Button("Cancel", role: .cancel) {} } message: { Text("This cannot be undone and will immediately update the plan and reports.") }
    }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
    private func deleteTransaction() async {
        guard let transaction else { return }
        isDeleting = true; defer { isDeleting = false }
        do { try await store.deleteTransaction(id: transaction.id) }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private struct LiveAccountsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showAdd = false
    private var activation: FreshBudgetActivationState {
        .init(accountCount: store.accounts.count, groupCount: store.groups.count, categoryCount: store.categories.count,
              canManageStructure: store.budget.can("manage_budget_structure"))
    }
    var body: some View {
        List {
            ForEach(store.accounts) { account in
                NavigationLink { LiveAccountRegisterView(account: account) } label: {
                    HStack { Label { VStack(alignment: .leading) { Text(account.name); Text(account.accountType.capitalized).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: account.accountType == "credit" ? "creditcard.fill" : "building.columns.fill") }; Spacer(); VStack(alignment: .trailing) { Text(store.format(store.balance(for: account))).monospacedDigit(); Text("Current").font(.caption).foregroundStyle(.secondary) } }
                }
            }
            if activation.needsAccount && !store.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add your first account").font(.headline)
                        Text("Start with where your money lives today. Add checking, savings, cash, or a credit card and enter its real current balance.").font(.subheadline).foregroundStyle(.secondary)
                        if activation.showsAddAccount {
                            Button { showAdd = true } label: { Label("Add Account", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("add-account-cta")
                        } else {
                            Text("A household owner can add accounts. Only accounts shared with you will appear here.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
        .accessibilityIdentifier("accounts-screen")
        .navigationTitle("Accounts")
        .toolbar { if store.budget.can("manage_budget_structure") { Button { showAdd = true } label: { Image(systemName:"plus") } } }
        .sheet(isPresented:$showAdd){AccountCreationView(budget:store.budget,serverURL:session.serverURL ?? URL(string:"http://localhost")!,token:session.token ?? "demo",onSaved:reload)}
    }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
}

struct LiveAccountRegisterView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let account: APIAccount
    @State private var showAdd = false
    @State private var showReconcile = false

    private var transactions: [APITransaction] { store.transactions(for: account) }
    private var paymentReserve: Int64? {
        guard let id = account.paymentCategoryID else { return nil }
        return store.summary?.categories.first(where: { $0.categoryID == id })?.availableMinor
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Working", value: store.format(store.balance(for: account)))
                LabeledContent("Cleared", value: store.format(store.clearedBalance(for: account)))
                LabeledContent("Uncleared", value: store.format(store.unclearedBalance(for: account)))
                if let reconciled = account.reconciledBalanceMinor {
                    LabeledContent("Last reconciled balance", value: store.format(reconciled))
                } else {
                    LabeledContent("Reconciliation", value: "Not reconciled")
                }
                if let paymentReserve { LabeledContent("Reserved for payment", value: store.format(paymentReserve)) }
            } header: {
                Text(account.name)
            }

            Section("Register") {
                if transactions.isEmpty {
                    ContentUnavailableView("No transactions", systemImage: "list.bullet.rectangle", description: Text("Transactions recorded in this account will appear here."))
                } else {
                    ForEach(transactions) { transaction in
                        LiveTransactionLink(transaction: transaction)
                            .badge(registerBadge(transaction))
                    }
                }
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.budget.can("create_transaction") { Button("Add Transaction", systemImage: "plus") { showAdd = true } }
                if store.budget.can("reconcile_account") { Button("Reconcile", systemImage: "checkmark.seal") { showReconcile = true } }
            }
        }
        .sheet(isPresented: $showAdd) { entry }
        .sheet(isPresented: $showReconcile) { reconcile }
        .refreshable { await store.refresh() }
    }

    private func registerBadge(_ transaction: APITransaction) -> String {
        var values: [String] = []
        if transaction.isReconciled { values.append("R") } else if transaction.isCleared { values.append("C") }
        if !transaction.splits.isEmpty { values.append("Split") }
        if transaction.transferID != nil { values.append("Transfer") }
        if transaction.memo.isEmpty == false || transaction.attachmentMetadata?.isEmpty == false { values.append("Details") }
        return values.joined(separator: " · ")
    }

    @ViewBuilder private var entry: some View {
        TransactionEntryView(budget: store.budget, accounts: store.accounts, categories: store.categories, serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", initialAccountID: account.id, onSaved: store.refresh)
    }
    @ViewBuilder private var reconcile: some View {
        LiveReconcileView(budget: store.budget, account: account, currentBalance: store.clearedBalance(for: account), serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: store.refresh)
    }
}

private struct LiveTransferView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let accounts: [APIAccount]; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID = ""; @State private var destinationID = ""; @State private var amount = ""; @State private var memo = ""; @State private var date = Date(); @State private var cleared = false; @State private var isSaving = false; @State private var errorMessage: String?
    private var openAccounts: [APIAccount] { accounts.filter { !$0.isClosed } }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode), value > 0 else { return nil }; return value }
    var body: some View {
        NavigationStack { Form {
            Picker("From", selection: $sourceID) { ForEach(openAccounts) { Text($0.name).tag($0.id) } }
            Picker("To", selection: $destinationID) { ForEach(openAccounts.filter { $0.id != sourceID }) { Text($0.name).tag($0.id) } }
            CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode); DatePicker("Date", selection: $date, displayedComponents: .date); TextField("Memo", text: $memo); Toggle("Cleared", isOn: $cleared)
        }.navigationTitle("Transfer").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(parsed == nil || sourceID.isEmpty || destinationID.isEmpty || sourceID == destinationID || isSaving) } }.onAppear { sourceID = openAccounts.first?.id ?? ""; selectDestination() }.onChange(of: sourceID) { _, _ in selectDestination() }.alert("Unable to transfer", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    }
    private func selectDestination() { if destinationID == sourceID || !openAccounts.contains(where: { $0.id == destinationID }) { destinationID = openAccounts.first(where: { $0.id != sourceID })?.id ?? "" } }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await workspace.createTransfer(APITransferCreate(sourceAccountID: sourceID, destinationAccountID: destinationID, amountMinor: parsed, occurredOn: BudgetWorkspaceStore.dateString(date), memo: memo, isCleared: cleared)); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LiveCategoryEditView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let category: APICategory; let groups: [APICategoryGroup]; let members: [APIHouseholdMember]; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String; @State private var groupID: String; @State private var sortOrder: Int; @State private var archived: Bool; @State private var delegatedUserID: String; @State private var isSaving = false; @State private var errorMessage: String?; @State private var confirmDelete = false
    init(budget: APIBudget, category: APICategory, groups: [APICategoryGroup], members: [APIHouseholdMember], serverURL: URL, token: String, onSaved: @escaping () async -> Void) {
        self.budget = budget; self.category = category; self.groups = groups; self.members = members; self.serverURL = serverURL; self.token = token; self.onSaved = onSaved
        _name = State(initialValue: category.name); _groupID = State(initialValue: category.groupID); _sortOrder = State(initialValue: category.sortOrder); _archived = State(initialValue: category.isArchived); _delegatedUserID = State(initialValue: category.delegatedUserID ?? "")
    }
    var body: some View { NavigationStack { Form { TextField("Name", text: $name); Picker("Group", selection: $groupID) { ForEach(groups.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } };Stepper("Order \(sortOrder)",value:$sortOrder,in:0...10_000); if budget.can("manage_allowances") { Picker("Delegated budget", selection: $delegatedUserID) { Text("Household / private").tag(""); ForEach(members.filter { $0.role != "owner" && $0.isActive }) { Text($0.displayName).tag($0.userID) } } }; Toggle("Archived", isOn: $archived); if archived { Text("Archived categories remain in historical reports but are hidden from new spending and assignments.").font(.footnote).foregroundStyle(.secondary) };Section{Button("Delete Unused Category",role:.destructive){confirmDelete=true};Text("Categories with transactions, allocations, targets, or other financial history cannot be deleted. Archive them instead.").font(.footnote).foregroundStyle(.secondary)} }.navigationTitle("Manage Category").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || groupID.isEmpty || isSaving) } }.confirmationDialog("Delete this category?",isPresented:$confirmDelete){Button("Delete Unused Category",role:.destructive){Task{await remove()}}}.alert("Unable to update category", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } } }
    private func save() async { isSaving = true; defer { isSaving = false }; do { try await workspace.updateCategory(id: category.id, value: APICategoryUpdate(groupID: groupID, name: name, sortOrder: sortOrder, isArchived: archived), delegatedUserID: delegatedUserID.isEmpty ? nil : delegatedUserID); dismiss() } catch { errorMessage = error.localizedDescription } }
    private func remove()async{isSaving=true;defer{isSaving=false};do{try await workspace.deleteCategory(id:category.id);dismiss()}catch{errorMessage=error.localizedDescription}}
}

private struct LiveReconcileView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let account: APIAccount; let currentBalance: Int64; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var statementBalance = ""; @State private var throughDate = Date(); @State private var createAdjustment = false; @State private var reason = ""; @State private var isSaving = false; @State private var errorMessage: String?
    private var parsed: Int64? { CurrencyText.parseMinorUnits(statementBalance, currencyCode: budget.currencyCode) }
    private var difference: Int64? { parsed.map { $0 - currentBalance } }
    var body: some View {
        NavigationStack { Form {
            Section("Statement") { LabeledContent("Current cleared estimate", value: CurrencyText.editable(currentBalance, currencyCode: budget.currencyCode)); CurrencyAmountField("Statement balance", text: $statementBalance, currencyCode: budget.currencyCode, allowsNegative: true, allowsZero: true); DatePicker("Through", selection: $throughDate, displayedComponents: .date) }
            if let difference, difference != 0 { Section("Difference") { LabeledContent("Adjustment", value: CurrencyText.editable(difference, currencyCode: budget.currencyCode)); Toggle("Create reconciliation adjustment", isOn: $createAdjustment); if createAdjustment { TextField("Adjustment reason", text: $reason) }; Text("The server calculates the authoritative cleared balance and will reject a mismatch unless you approve an adjustment.").font(.footnote).foregroundStyle(.secondary) } }
        }.navigationTitle("Reconcile \(account.name)").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Reconcile") { Task { await save() } }.disabled(parsed == nil || isSaving) } }.onAppear { statementBalance = CurrencyText.editable(currentBalance, currencyCode: budget.currencyCode) }.alert("Unable to reconcile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await workspace.reconcile(accountID: account.id, statementBalance: parsed, throughDate: BudgetWorkspaceStore.dateString(throughDate), createAdjustment: createAdjustment, reason: reason); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LiveInsightsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showFilters = false
    @State private var breakdownMode = SpendingBreakdownMode.category
    @State private var selectedAngle: Int64?
    @State private var selectedSlice: SpendingBreakdownSlice?
    var body: some View {
        List {
            Section { Picker("Period", selection: $store.reportPeriod) { Text("30 Days").tag("30d"); Text("60 Days").tag("60d"); Text("90 Days").tag("90d"); Text("3 Months").tag("3m"); Text("6 Months").tag("6m"); Text("Year to Date").tag("ytd"); Text("1 Year").tag("1y"); Text("Custom").tag("custom") }.onChange(of: store.reportPeriod) { _, _ in Task { await reload() } }; if store.reportPeriod == "custom" { DatePicker("From", selection: $store.customReportStart, displayedComponents: .date); DatePicker("Through", selection: $store.customReportEnd, displayedComponents: .date); Button("Apply custom range") { Task { await reload() } } } }
            if let report = store.spendingReport {
                SpendingBreakdownView(report: report, mode: $breakdownMode, selectedAngle: $selectedAngle, selectedSlice: $selectedSlice)
                Section("Ranked breakdown") { ForEach(SpendingBreakdownSlice.make(from: report, mode: breakdownMode)) { slice in Button { selectedSlice = slice } label: { HStack { Image(systemName: "circle.fill").foregroundStyle(Theme.accent); VStack(alignment: .leading) { Text(slice.name); Text(slice.percentage(of: report.totalSpendingMinor).formatted(.percent.precision(.fractionLength(1)))).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(store.format(slice.spendingMinor)).monospacedDigit() }.foregroundStyle(.primary) } } }
            } else if let message = store.errorMessage {
                Section { ContentUnavailableView("Unable to load spending", systemImage: "exclamationmark.triangle", description: Text(message)); Button("Retry") { Task { await reload() } } }
            } else {
                Section { ContentUnavailableView("No spending in this range", systemImage: "chart.pie", description: Text("Try a wider date range or different filters.")) }
            }
            if store.reportCategoryID.isEmpty, store.reportCategoryGroup.isEmpty, store.reportTransactionType.isEmpty, let report = store.incomeReport { Section("Income vs. spending") { LabeledContent("Income", value: store.format(report.incomeMinor)); LabeledContent("Spending", value: store.format(report.spendingMinor)); LabeledContent("Difference", value: store.format(report.differenceMinor)); if let rate = report.savingsRate { LabeledContent("Savings rate", value: rate.formatted(.percent.precision(.fractionLength(0)))) } } }
        }.navigationTitle("Insights").toolbar { Button { showFilters = true } label: { Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") } }.sheet(isPresented: $showFilters) { filters }.navigationDestination(item: $selectedSlice) { slice in if slice.mode == .group { LiveReportGroupView(group: slice.name) } else if let category = store.spendingReport?.categories.first(where: { $0.categoryID == slice.id }) { LiveReportCategoryView(category: category) } }
    }
    private var hasFilters: Bool { !store.reportAccountID.isEmpty || !store.reportCategoryID.isEmpty || !store.reportCategoryGroup.isEmpty || !store.reportPayee.isEmpty || !store.reportMemberID.isEmpty || !store.reportTransactionType.isEmpty || store.reportCleared != "all" || store.includeTrackingAccounts }
    private var filters: some View { NavigationStack { Form {
        Picker("Account", selection: $store.reportAccountID) { Text("All accounts").tag(""); ForEach(store.accounts) { Text($0.name).tag($0.id) } }
        Picker("Category", selection: $store.reportCategoryID) { Text("All categories").tag(""); ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } }
        Picker("Category group", selection: $store.reportCategoryGroup) { Text("All groups").tag(""); ForEach(store.groups) { Text($0.name).tag($0.name) } }
        Picker("Payee", selection: $store.reportPayee) { Text("All payees").tag(""); ForEach(Array(Set(store.transactions.map(\.payeeName))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) } }
        if !store.householdMembers.isEmpty { Picker("Member", selection: $store.reportMemberID) { Text("All members").tag(""); ForEach(store.householdMembers.filter(\.isActive)) { Text($0.displayName).tag($0.userID) } } }
        Picker("Type", selection: $store.reportTransactionType) { Text("All types").tag(""); Text("Spending").tag("spending"); Text("Refunds").tag("refund"); Text("Income").tag("income"); Text("Transfers").tag("transfer") }
        Picker("Status", selection: $store.reportCleared) { Text("All statuses").tag("all"); Text("Cleared").tag("cleared"); Text("Uncleared").tag("uncleared") }
        Toggle("Include tracking accounts", isOn: $store.includeTrackingAccounts)
    }.navigationTitle("Report Filters").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Reset") { store.reportAccountID = ""; store.reportCategoryID = ""; store.reportCategoryGroup = ""; store.reportPayee = ""; store.reportMemberID = ""; store.reportTransactionType = ""; store.reportCleared = "all"; store.includeTrackingAccounts = false } }; ToolbarItem(placement: .confirmationAction) { Button("Apply") { showFilters = false; Task { await reload() } } } } } }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
}

enum SpendingBreakdownMode: String, CaseIterable, Identifiable { case group = "Groups", category = "Categories"; var id: Self { self } }

struct SpendingBreakdownSlice: Identifiable, Hashable {
    let id: String
    let name: String
    let spendingMinor: Int64
    let transactionIDs: [String]
    let mode: SpendingBreakdownMode

    static func make(from report: APISpendingReport, mode: SpendingBreakdownMode) -> [Self] {
        if mode == .category {
            return report.categories.filter { $0.spendingMinor > 0 }.map { Self(id: $0.categoryID, name: $0.categoryName, spendingMinor: $0.spendingMinor, transactionIDs: $0.transactionIDs, mode: mode) }.sorted { $0.spendingMinor > $1.spendingMinor }
        }
        let groups = Dictionary(grouping: report.categories.filter { $0.spendingMinor > 0 }, by: \.categoryGroup)
        return groups.map { name, rows in Self(id: "group:\(name)", name: name, spendingMinor: rows.reduce(Int64(0)) { $0 + $1.spendingMinor }, transactionIDs: Array(Set(rows.flatMap(\.transactionIDs))).sorted(), mode: mode) }.sorted { $0.spendingMinor > $1.spendingMinor }
    }

    func percentage(of total: Int64) -> Double { total > 0 ? Double(spendingMinor) / Double(total) : 0 }
}

private struct SpendingBreakdownView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APISpendingReport
    @Binding var mode: SpendingBreakdownMode
    @Binding var selectedAngle: Int64?
    @Binding var selectedSlice: SpendingBreakdownSlice?
    private var slices: [SpendingBreakdownSlice] { SpendingBreakdownSlice.make(from: report, mode: mode) }

    var body: some View {
        Section("Spending Breakdown") {
            Picker("Break down by", selection: $mode) { ForEach(SpendingBreakdownMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if slices.isEmpty || report.totalSpendingMinor <= 0 {
                ContentUnavailableView("No spending in this range", systemImage: "chart.pie", description: Text("Try a wider date range or different filters."))
            } else {
                ZStack {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Spending", slice.spendingMinor), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(by: .value(mode.rawValue, slice.name))
                            .accessibilityLabel(slice.name)
                            .accessibilityValue("\(store.format(slice.spendingMinor)), \(slice.percentage(of: report.totalSpendingMinor).formatted(.percent.precision(.fractionLength(1))))")
                    }
                    .chartAngleSelection(value: $selectedAngle)
                    .chartLegend(.hidden)
                    VStack { Text("Total").font(.caption).foregroundStyle(.secondary); Text(store.format(report.totalSpendingMinor)).font(.headline).minimumScaleFactor(0.7) }
                }
                .frame(minHeight: 260)
                .accessibilityIdentifier("spending-breakdown-sector-chart")
                .onChange(of: selectedAngle) { _, value in if let value { selectedSlice = slice(at: value) } }
            }
        }
    }

    private func slice(at angle: Int64) -> SpendingBreakdownSlice? {
        var upper: Int64 = 0
        for slice in slices { upper += slice.spendingMinor; if angle <= upper { return slice } }
        return nil
    }
}

private struct LiveReportGroupView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let group: String
    private var categories: [APISpendingCategoryReport] { store.spendingReport?.categories.filter { $0.categoryGroup == group && $0.spendingMinor > 0 }.sorted { $0.spendingMinor > $1.spendingMinor } ?? [] }
    var body: some View { List { Section { LabeledContent("Total", value: store.format(categories.reduce(Int64(0)) { $0 + $1.spendingMinor })) }; Section("Categories") { ForEach(categories) { category in NavigationLink { LiveReportCategoryView(category: category) } label: { LabeledContent(category.categoryName, value: store.format(category.spendingMinor)) } } } }.navigationTitle(group) }
}

private struct LiveReportCategoryView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let category: APISpendingCategoryReport
    // Re-derive from the live report so that editing a transaction out of this category
    // recalculates the total/contributing rows on return instead of showing a stale snapshot.
    private var liveRow: APISpendingCategoryReport? { store.spendingReport?.categories.first { $0.categoryID == category.categoryID } }
    private var reportLoaded: Bool { store.spendingReport != nil }
    private var displayName: String { liveRow?.categoryName ?? category.categoryName }
    private var spendingMinor: Int64 { reportLoaded ? (liveRow?.spendingMinor ?? 0) : category.spendingMinor }
    private var contributingIDs: [String] { reportLoaded ? (liveRow?.transactionIDs ?? []) : category.transactionIDs }
    var transactions: [APITransaction] { store.transactions.filter { contributingIDs.contains($0.id) } }
    var body: some View {
        List {
            Section {
                LabeledContent("Total", value: store.format(spendingMinor))
                LabeledContent("Transactions", value: "\(transactions.count)")
                LabeledContent("Average", value: store.format(transactions.isEmpty ? 0 : spendingMinor / Int64(transactions.count)))
            }
            if transactions.isEmpty {
                Section { ContentUnavailableView("No spending in this range", systemImage: "tray") }
            } else {
                Section("Transactions") { ForEach(transactions) { LiveTransactionLink(transaction: $0) } }
            }
        }.navigationTitle(displayName)
    }
}

struct LiveHouseholdView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Signed in") {
                    LabeledContent("Member", value: session.profile?.displayName ?? "Demo household")
                    LabeledContent("Role", value: store.budget.effectivePermission.rawValue.capitalized)
                }
                if store.budget.can("manage_allowances") {
                    Section("Delegated budgets") {
                        ForEach(store.householdMembers.filter { $0.role != "owner" && $0.isActive }) { member in
                            NavigationLink { LiveDelegatedPolicyView(session: session, store: store, member: member) } label: {
                                VStack(alignment: .leading) {
                                    Text(member.displayName)
                                    if let policy = store.delegatedBudgets.first(where: { $0.userID == member.userID }) {
                                        Text("Authority \(store.format(policy.authorityMinor)) · \(policy.allowReallocation ? "can reallocate" : "locked")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Not configured").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Self-hosting") {
                    LabeledContent("Data Source", value: session.sourceMode.title)
                    LabeledContent("Status", value: session.connectionStatus.title)
                    LabeledContent("Server", value: session.serverURL?.absoluteString ?? "No live server configured")
                    NavigationLink("Server Connection") { ServerConnectionSettingsView() }
                    Label("Manual entry only — no bank connections", systemImage: "building.columns")
                }
            }
            .navigationTitle("Household")
            .toolbar { Button("Done") { dismiss() } }
        }
        .environmentObject(session)
        .environmentObject(store)
        .accessibilityIdentifier("household-profile-screen")
    }
}

struct LiveDelegatedPolicyView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var store: BudgetWorkspaceStore
    let member: APIHouseholdMember
    @State private var poolCategoryID = ""; @State private var authority = ""; @State private var allowCreation = true; @State private var allowReallocation = true; @State private var isSaving = false; @State private var errorMessage: String?
    private var categories: [APICategory] { store.categories.filter { $0.delegatedUserID == member.userID && !$0.isArchived } }
    var body: some View { Form { Section("Authority") { Picker("To assign category", selection: $poolCategoryID) { ForEach(categories) { Text($0.name).tag($0.id) } }; CurrencyAmountField("Total authority", text: $authority, currencyCode: store.budget.currencyCode, allowsZero: true); Toggle("Can create categories", isOn: $allowCreation); Toggle("Can move money", isOn: $allowReallocation) }; Section { Text("Authority is a hard household boundary. The member can organize only categories delegated to them, and cannot expose or move money into private family categories.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle(member.displayName).toolbar { Button("Save") { Task { await save() } }.disabled(poolCategoryID.isEmpty || parsed == nil || isSaving) }.onAppear { let existing = store.delegatedBudgets.first(where: { $0.userID == member.userID }); poolCategoryID = existing?.poolCategoryID ?? categories.first?.id ?? ""; authority = CurrencyText.editable(existing?.authorityMinor ?? 0, currencyCode: store.budget.currencyCode); allowCreation = existing?.allowCategoryCreation ?? true; allowReallocation = existing?.allowReallocation ?? true }.alert("Unable to save delegated budget", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    private var parsed: Int64? { guard let amount = CurrencyText.parseMinorUnits(authority, currencyCode: store.budget.currencyCode), amount >= 0 else { return nil }; return amount }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await store.updateDelegatedPolicy(userID: member.userID, value: APIDelegatedBudgetUpsert(userID: member.userID, poolCategoryID: poolCategoryID, authorityMinor: parsed, allowCategoryCreation: allowCreation, allowReallocation: allowReallocation, expectedAllocationVersion: store.summary?.allocationVersion)) } catch { errorMessage = error.localizedDescription } }
}

private struct LiveTransactionEditView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let transaction: APITransaction; let accounts: [APIAccount]; let categories: [APICategory]; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var payee: String; @State private var amount: String; @State private var accountID: String; @State private var categoryID: String; @State private var memo: String; @State private var cleared: Bool; @State private var date: Date; @State private var isInflow: Bool; @State private var isSplit: Bool; @State private var splitRows: [WorkspaceSplitDraft]; @State private var flag: String; @State private var tags: String; @State private var attachments: String
    @State private var isSaving = false; @State private var errorMessage: String?
    init(budget: APIBudget, transaction: APITransaction, accounts: [APIAccount], categories: [APICategory], serverURL: URL, token: String, onSaved: @escaping () async -> Void) {
        self.budget=budget; self.transaction=transaction; self.accounts=accounts; self.categories=categories; self.serverURL=serverURL; self.token=token; self.onSaved=onSaved
        _payee=State(initialValue:transaction.payeeName); _amount=State(initialValue:CurrencyText.editable(abs(transaction.amountMinor),currencyCode:budget.currencyCode)); _accountID=State(initialValue:transaction.accountID); _categoryID=State(initialValue:transaction.categoryID ?? ""); _memo=State(initialValue:transaction.memo); _cleared=State(initialValue:transaction.isCleared); _date=State(initialValue:Self.parseDate(transaction.occurredOn)); _isInflow=State(initialValue:transaction.amountMinor > 0); _isSplit=State(initialValue:!transaction.splits.isEmpty); _splitRows=State(initialValue:transaction.splits.map { WorkspaceSplitDraft(categoryID:$0.categoryID,amount:CurrencyText.editable(abs($0.amountMinor),currencyCode:budget.currencyCode),memo:$0.memo) }); _flag=State(initialValue:transaction.flag ?? ""); _tags=State(initialValue:(transaction.tags ?? []).joined(separator:", ")); _attachments=State(initialValue:(transaction.attachmentMetadata ?? []).compactMap{$0["name"]}.joined(separator:", "))
    }
    var body: some View { NavigationStack { Form {
        TextField("Payee",text:$payee); CurrencyAmountField("Amount", text:$amount, currencyCode:budget.currencyCode); Toggle("Income / inflow",isOn:$isInflow); Picker("Account",selection:$accountID){ForEach(accounts.filter{!$0.isClosed}){Text($0.name).tag($0.id)}}; DatePicker("Date",selection:$date,displayedComponents:.date); Toggle("Split across categories",isOn:$isSplit).disabled(isInflow)
        if isSplit { Section("Splits") { ForEach($splitRows) { $row in Picker("Category",selection:$row.categoryID){Text("Select").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}};CurrencyAmountField("Split amount", text:$row.amount, currencyCode:budget.currencyCode, allowsZero:true);TextField("Split memo",text:$row.memo) }; Button("Add split",systemImage:"plus"){splitRows.append(.init())}; if let remaining { LabeledContent("Remaining",value:CurrencyText.editable(remaining,currencyCode:budget.currencyCode)).foregroundStyle(remaining == 0 ? Color.secondary : Color.red) } } } else if !isInflow { Picker("Category",selection:$categoryID){Text("Uncategorized").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}} }
        TextField("Memo",text:$memo); Picker("Flag",selection:$flag){Text("None").tag("");Text("Red").tag("red");Text("Orange").tag("orange");Text("Yellow").tag("yellow");Text("Green").tag("green");Text("Blue").tag("blue");Text("Purple").tag("purple")}; TextField("Tags (comma separated)",text:$tags);TextField("Attachment names (metadata only)",text:$attachments);Toggle("Cleared",isOn:$cleared)
    }.navigationTitle("Edit Transaction").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(isSaving || parsed == nil || !splitsValid)} }.alert("Unable to save",isPresented:Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})){Button("OK",role:.cancel){}}message:{Text(errorMessage ?? "Unknown error")} } }
    private var parsed:Int64?{guard let value=CurrencyText.parseMinorUnits(amount,currencyCode:budget.currencyCode),value>0 else{return nil};return isInflow ? value : -value}
    private var parsedSplits:[APITransactionSplitCreate]?{guard isSplit else{return []};var values:[APITransactionSplitCreate]=[];for row in splitRows{guard !row.categoryID.isEmpty,let value=CurrencyText.parseMinorUnits(row.amount,currencyCode:budget.currencyCode),value>=0 else{return nil};values.append(.init(categoryID:row.categoryID,amountMinor:-value,memo:row.memo))};return values}
    private var remaining:Int64?{guard let parsed,let parsedSplits else{return nil};return parsed - parsedSplits.reduce(0){$0+$1.amountMinor}}
    private var splitsValid:Bool{!isSplit || (parsedSplits?.count ?? 0)>=2 && remaining==0}
    private func save() async { guard let parsed,let parsedSplits else{return};isSaving=true;defer{isSaving=false};do{try await workspace.updateTransaction(id:transaction.id,value:APITransactionCreate(accountID:accountID,categoryID:isSplit || isInflow || categoryID.isEmpty ? nil:categoryID,amountMinor:parsed,occurredOn:BudgetWorkspaceStore.dateString(date),payeeName:payee,memo:memo,isCleared:cleared,splits:parsedSplits,flag:flag.isEmpty ? nil:flag,tags:commaValues(tags),attachmentMetadata:commaValues(attachments).map{["name":$0]}));dismiss()}catch{errorMessage=error.localizedDescription} }
    private func commaValues(_ value:String)->[String]{value.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}}
    private static func parseDate(_ value:String)->Date{let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd";return formatter.date(from:value) ?? Date()}
}

private struct WorkspaceSplitDraft:Identifiable{let id=UUID();var categoryID="";var amount="";var memo=""}
