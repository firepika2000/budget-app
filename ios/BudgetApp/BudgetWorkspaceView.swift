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

private struct WorkspaceSnapshot {
    var accounts: [APIAccount]; var accountBalances: [String: APIAccountBalance]; var categories: [APICategory]; var groups: [APICategoryGroup]
    var transactions: [APITransaction]; var summary: APIMonthSummary?
    var requests: [APIFinancialRequest]; var allowances: [APIAllowancePlan]
    var spending: APISpendingReport?; var income: APIIncomeSpendingReport?
    var delegated: APIDelegatedBudget?; var forecast: APIForecast?
    var members: [APIHouseholdMember]; var delegatedBudgets: [APIDelegatedBudget]
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

    init() {
        let store = DemoStore()
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
        let groupNames = Array(Set(visibleCategories.map(\.group))).sorted()
        let groupIDs = Dictionary(uniqueKeysWithValues: groupNames.map { ($0, "demo-group-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))") })
        let groupRows: [APICategoryGroup] = try decode(groupNames.enumerated().map { ["id": groupIDs[$0.element]!, "budget_id": budget.id, "name": $0.element, "sort_order": $0.offset] })
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
        let summary: APIMonthSummary = try decode(["month": month, "currency_code": "USD", "ready_to_assign_minor": demo.readyToAssign, "total_assigned_minor": visibleCategories.reduce(0) { $0 + $1.assigned }, "total_overspent_minor": visibleCategories.reduce(0) { $0 + max(-$1.available, 0) }, "allocation_version": 1, "categories": visibleCategories.map { ["category_id": $0.id, "name": $0.name, "assigned_minor": $0.assigned, "activity_minor": $0.activity, "carried_available_minor": 0, "available_minor": $0.available, "is_overspent": $0.available < 0] }])
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
        return WorkspaceSnapshot(accounts: accountRows, accountBalances: Dictionary(uniqueKeysWithValues: accountBalanceRows.map { ($0.accountID, $0) }), categories: categoryRows, groups: groupRows, transactions: transactionRows, summary: summary, requests: requestRows, allowances: [], spending: spending, income: income, delegated: delegated, forecast: nil, members: [], delegatedBudgets: [])
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
    static func demo() -> BudgetWorkspaceStore { BudgetWorkspaceStore(dataSource: DemoWorkspaceDataSource()) }

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
                householdMembers = value.members; delegatedBudgets = value.delegatedBudgets; errorMessage = nil
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

    func createAccount(_ value: APIAccountCreate) async throws {
        if let demoSource = dataSource as? DemoWorkspaceDataSource { demoSource.demo.createAccount(name: value.name, type: value.accountType, isOnBudget: value.isOnBudget) }
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

    func categoryName(_ transaction: APITransaction) -> String {
        let ids = transaction.categoryID.map { [$0] } ?? transaction.splits.map(\.categoryID)
        return ids.compactMap { id in categories.first(where: { $0.id == id })?.name }.joined(separator: ", ")
    }

    func balance(for account: APIAccount) -> Int64 {
        accountBalances[account.id]?.workingBalanceMinor ?? transactions.filter { $0.accountID == account.id }.reduce(0) { $0 + $1.amountMinor }
    }
    func clearedBalance(for account: APIAccount) -> Int64 { accountBalances[account.id]?.clearedBalanceMinor ?? transactions.filter { $0.accountID == account.id && $0.isCleared }.reduce(0) { $0 + $1.amountMinor } }

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
}

struct BudgetWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var store: BudgetWorkspaceStore
    @State private var showingSettings = false
    @State private var selectedTab: Int

    init(budget: APIBudget) { _store = StateObject(wrappedValue: BudgetWorkspaceStore(budget: budget)); _selectedTab = State(initialValue: 0) }
    private init(demo: Bool) { _store = StateObject(wrappedValue: .demo()); let screen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-screen=") }?.split(separator: "=").last.map(String.init) ?? "home"; _selectedTab = State(initialValue: ["home":0,"plan":1,"activity":2,"transaction":2,"accounts":3,"credit":3,"insights":4][screen] ?? 0) }
    static func demo() -> BudgetWorkspaceView { BudgetWorkspaceView(demo: true) }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { LiveHomeView(showSettings: { showingSettings = true }) }.tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack { LivePlanView() }.tabItem { Label("Plan", systemImage: "square.grid.2x2.fill") }.tag(1)
            NavigationStack { LiveActivityView() }.tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { LiveAccountsView() }.tabItem { Label("Accounts", systemImage: "creditcard.fill") }.tag(3)
            NavigationStack { LiveInsightsView() }.tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }.tag(4)
        }
        .environmentObject(store)
        .tint(Theme.accent)
        .overlay { if store.isLoading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await reload() }
        .alert("Unable to complete request", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Retry") { Task { await reload() } }; Button("Cancel", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "Unknown error") }
        .sheet(isPresented: $showingSettings) { LiveHouseholdView() }
    }

    private func reload() async {
        if ProcessInfo.processInfo.arguments.contains("--demo") || session.serverURL == nil && session.token == nil {
            await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
            return
        }
        do { try await session.refreshIfNeeded() } catch { store.errorMessage = error.localizedDescription; return }
        guard let url = session.serverURL, let token = session.token else { return }
        await store.load(serverURL: url, token: token)
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
                    ForEach(summary.categories.filter(\.isOverspent)) { row in Label("\(row.name) is overspent by \(store.format(abs(row.availableMinor)))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
                    ForEach(store.requests.filter { $0.status == "pending" }) { request in NavigationLink { LiveRequestDetailView(requestID: request.id) } label: { Label("Request pending · \(store.format(request.requestedAmountMinor))", systemImage: "hand.raised.fill") } }
                }
            }
            Section("Recent activity") { ForEach(store.transactions.prefix(5)) { LiveTransactionLink(transaction: $0) } }
            if let forecast = store.forecast { Section("90-day forecast") { LabeledContent("Projected total", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest projected", value: store.format(forecast.lowestProjectedTotalMinor)); NavigationLink("View forecast") { LiveForecastView() } } }
        }.navigationTitle(store.budget.name).toolbar { ToolbarItem(placement: .topBarLeading) { Button(action: showSettings) { Image(systemName: "person.crop.circle") } } }
    }
}

private struct LiveForecastView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { if let forecast = store.forecast { Section("Household cash") { LabeledContent("Today", value: store.format(forecast.actualTotalOnBudgetMinor)); LabeledContent("At \(forecast.through)", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest", value: store.format(forecast.lowestProjectedTotalMinor)) }; Section("Accounts") { ForEach(forecast.accounts) { account in VStack(alignment: .leading) { Text(account.name); HStack { Text("Now \(store.format(account.actualBalanceMinor))"); Spacer(); Text("Projected \(store.format(account.projectedBalanceMinor))") }.font(.caption).foregroundStyle(.secondary) } } }; Section("Scheduled activity") { if forecast.occurrences.isEmpty { Text("No scheduled transactions in this period").foregroundStyle(.secondary) }; ForEach(forecast.occurrences) { item in HStack { VStack(alignment: .leading) { Text(item.name); Text(item.occurredOn).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(store.format(item.amountMinor)).monospacedDigit() } } } } }.navigationTitle("Forecast") }
}

private struct LiveRequestDetailView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let requestID: String
    @State private var amount = ""; @State private var sourceCategoryID = ""; @State private var note = ""; @State private var isSaving = false; @State private var errorMessage: String?
    private var request: APIFinancialRequest? { store.requests.first(where: { $0.id == requestID }) }
    private var sources: [APICategoryMonth] { (store.summary?.categories ?? []).filter { $0.availableMinor > 0 && $0.categoryID != request?.destinationCategoryID } }
    var body: some View { Form { if let request { Section("Request") { LabeledContent("Requester", value: requesterName(request.requesterUserID)); LabeledContent("Amount", value: store.format(request.requestedAmountMinor)); LabeledContent("Category", value: store.categories.first(where: { $0.id == request.destinationCategoryID })?.name ?? "Category"); LabeledContent("Reason", value: request.reason.isEmpty ? "—" : request.reason) }; if store.budget.can("approve_request") && request.status == "pending" { Section("Decision") { Picker("Fund from", selection: $sourceCategoryID) { ForEach(sources) { Text("\($0.name) · \(store.format($0.availableMinor))").tag($0.categoryID) } }; TextField("Approved amount", text: $amount).keyboardType(.decimalPad); TextField("Note", text: $note) }; Section { Button("Approve") { Task { await decide("approve") } }.disabled(parsed == nil || sourceCategoryID.isEmpty || isSaving); Button("Request changes") { Task { await decide("changes_requested") } }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving); Button("Reject", role: .destructive) { Task { await decide("reject") } }.disabled(isSaving) } }; Section("History") { ForEach(request.actions) { action in VStack(alignment: .leading) { Text(action.action.replacingOccurrences(of: "_", with: " ").capitalized); if !action.note.isEmpty { Text(action.note).font(.caption).foregroundStyle(.secondary) } } } } } }.navigationTitle("Funding Request").onAppear { if let request { amount = CurrencyText.editable(request.requestedAmountMinor, currencyCode: store.budget.currencyCode); sourceCategoryID = sources.first?.categoryID ?? "" } }.alert("Unable to decide request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
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
                Section("Available to assign") { Text(store.format(summary.readyToAssignMinor)).font(.largeTitle.bold()).monospacedDigit() }
            }
            Section("Plan") {
                HStack { Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }; Spacer(); Text(store.planMonth.formatted(.dateTime.month(.wide).year())).font(.headline); Spacer(); Button { changeMonth(1) } label: { Image(systemName: "chevron.right") } }
                ForEach(store.summary?.categories ?? []) { category in
                    Button { if store.budget.can("assign_money") { editing = category } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(category.name); Spacer(); Text(store.format(category.availableMinor)).fontWeight(.semibold) }
                            HStack { Text("Assigned \(store.format(category.assignedMinor))"); Spacer(); Text("Activity \(store.format(category.activityMinor))") }.font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary)
                    }.contextMenu { if let model = store.categories.first(where: { $0.id == category.categoryID }), canManage(model) { Button("Manage Category", systemImage: "pencil") { managing = model } } }
                }
            }
        }.navigationTitle("Plan").toolbar {
            Menu {
                if store.budget.can("assign_money") { Button("Smart Funding", systemImage: "sparkles") { showSmartFunding = true } }
                if store.budget.can("manage_budget_structure") || store.budget.can("manage_own_categories") { Button("Add category", systemImage: "folder.badge.plus") { showCategory = true } }
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
        List { ForEach(filtered) { LiveTransactionLink(transaction: $0) } }
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
    @State private var reconciling: APIAccount?
    @State private var showAdd = false
    var body: some View { List(store.accounts) { account in Button { if store.budget.can("reconcile_account") { reconciling = account } } label: { HStack { Label { VStack(alignment: .leading) { Text(account.name); Text(account.accountType.capitalized).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: account.accountType == "credit" ? "creditcard.fill" : "building.columns.fill") }; Spacer(); VStack(alignment: .trailing) { Text(store.format(store.balance(for: account))).monospacedDigit(); Text("Current").font(.caption).foregroundStyle(.secondary) } }.foregroundStyle(.primary) } }.navigationTitle("Accounts").toolbar { if store.budget.can("manage_budget_structure") { Button { showAdd = true } label: { Image(systemName:"plus") } } }.sheet(item: $reconciling) { account in LiveReconcileView(budget: store.budget, account: account, currentBalance: store.clearedBalance(for: account), serverURL: session.serverURL ?? URL(string: "http://localhost")!, token: session.token ?? "demo", onSaved: reload) }.sheet(isPresented:$showAdd){AccountCreationView(budget:store.budget,serverURL:session.serverURL ?? URL(string:"http://localhost")!,token:session.token ?? "demo",onSaved:reload)} }
    private func reload() async { guard let url = session.serverURL, let token = session.token else { return }; await store.load(serverURL: url, token: token) }
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
            TextField("Amount", text: $amount).keyboardType(.decimalPad); DatePicker("Date", selection: $date, displayedComponents: .date); TextField("Memo", text: $memo); Toggle("Cleared", isOn: $cleared)
        }.navigationTitle("Transfer").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(parsed == nil || sourceID.isEmpty || destinationID.isEmpty || sourceID == destinationID || isSaving) } }.onAppear { sourceID = openAccounts.first?.id ?? ""; selectDestination() }.onChange(of: sourceID) { _, _ in selectDestination() }.alert("Unable to transfer", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    }
    private func selectDestination() { if destinationID == sourceID || !openAccounts.contains(where: { $0.id == destinationID }) { destinationID = openAccounts.first(where: { $0.id != sourceID })?.id ?? "" } }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await workspace.createTransfer(APITransferCreate(sourceAccountID: sourceID, destinationAccountID: destinationID, amountMinor: parsed, occurredOn: BudgetWorkspaceStore.dateString(date), memo: memo, isCleared: cleared)); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LiveCategoryEditView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let category: APICategory; let groups: [APICategoryGroup]; let members: [APIHouseholdMember]; let serverURL: URL; let token: String; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String; @State private var groupID: String; @State private var archived: Bool; @State private var delegatedUserID: String; @State private var isSaving = false; @State private var errorMessage: String?
    init(budget: APIBudget, category: APICategory, groups: [APICategoryGroup], members: [APIHouseholdMember], serverURL: URL, token: String, onSaved: @escaping () async -> Void) {
        self.budget = budget; self.category = category; self.groups = groups; self.members = members; self.serverURL = serverURL; self.token = token; self.onSaved = onSaved
        _name = State(initialValue: category.name); _groupID = State(initialValue: category.groupID); _archived = State(initialValue: category.isArchived); _delegatedUserID = State(initialValue: category.delegatedUserID ?? "")
    }
    var body: some View { NavigationStack { Form { TextField("Name", text: $name); Picker("Group", selection: $groupID) { ForEach(groups) { Text($0.name).tag($0.id) } }; if budget.can("manage_allowances") { Picker("Delegated budget", selection: $delegatedUserID) { Text("Household / private").tag(""); ForEach(members.filter { $0.role != "owner" && $0.isActive }) { Text($0.displayName).tag($0.userID) } } }; Toggle("Archived", isOn: $archived); if archived { Text("Archived categories remain in historical reports but are hidden from new spending and assignments.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Manage Category").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || groupID.isEmpty || isSaving) } }.alert("Unable to update category", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } } }
    private func save() async { isSaving = true; defer { isSaving = false }; do { try await workspace.updateCategory(id: category.id, value: APICategoryUpdate(groupID: groupID, name: name, sortOrder: category.sortOrder, isArchived: archived), delegatedUserID: delegatedUserID.isEmpty ? nil : delegatedUserID); dismiss() } catch { errorMessage = error.localizedDescription } }
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
            Section("Statement") { LabeledContent("Current cleared estimate", value: CurrencyText.editable(currentBalance, currencyCode: budget.currencyCode)); TextField("Statement balance", text: $statementBalance).keyboardType(.numbersAndPunctuation); DatePicker("Through", selection: $throughDate, displayedComponents: .date) }
            if let difference, difference != 0 { Section("Difference") { LabeledContent("Adjustment", value: CurrencyText.editable(difference, currencyCode: budget.currencyCode)); Toggle("Create reconciliation adjustment", isOn: $createAdjustment); if createAdjustment { TextField("Adjustment reason", text: $reason) }; Text("The server calculates the authoritative cleared balance and will reject a mismatch unless you approve an adjustment.").font(.footnote).foregroundStyle(.secondary) } }
        }.navigationTitle("Reconcile \(account.name)").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Reconcile") { Task { await save() } }.disabled(parsed == nil || isSaving) } }.onAppear { statementBalance = CurrencyText.editable(currentBalance, currencyCode: budget.currencyCode) }.alert("Unable to reconcile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await workspace.reconcile(accountID: account.id, statementBalance: parsed, throughDate: BudgetWorkspaceStore.dateString(throughDate), createAdjustment: createAdjustment, reason: reason); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LiveInsightsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showFilters = false
    var body: some View {
        List {
            Section { Picker("Period", selection: $store.reportPeriod) { Text("30 Days").tag("30d"); Text("60 Days").tag("60d"); Text("90 Days").tag("90d"); Text("3 Months").tag("3m"); Text("6 Months").tag("6m"); Text("Year to Date").tag("ytd"); Text("1 Year").tag("1y"); Text("Custom").tag("custom") }.onChange(of: store.reportPeriod) { _, _ in Task { await reload() } }; if store.reportPeriod == "custom" { DatePicker("From", selection: $store.customReportStart, displayedComponents: .date); DatePicker("Through", selection: $store.customReportEnd, displayedComponents: .date); Button("Apply custom range") { Task { await reload() } } } }
            if let report = store.spendingReport {
                Section { LabeledContent("Total spending", value: store.format(report.totalSpendingMinor)); Chart(report.categories) { BarMark(x: .value("Spending", $0.spendingMinor), y: .value("Category", $0.categoryName)).foregroundStyle(Theme.accent) }.frame(minHeight: 180) }
                Section("Spending by category") { ForEach(report.categories) { category in NavigationLink { LiveReportCategoryView(category: category) } label: { LabeledContent(category.categoryName, value: store.format(category.spendingMinor)) } } }
            }
            if store.reportCategoryID.isEmpty, store.reportCategoryGroup.isEmpty, store.reportTransactionType.isEmpty, let report = store.incomeReport { Section("Income vs. spending") { LabeledContent("Income", value: store.format(report.incomeMinor)); LabeledContent("Spending", value: store.format(report.spendingMinor)); LabeledContent("Difference", value: store.format(report.differenceMinor)); if let rate = report.savingsRate { LabeledContent("Savings rate", value: rate.formatted(.percent.precision(.fractionLength(0)))) } } }
        }.navigationTitle("Insights").toolbar { Button { showFilters = true } label: { Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") } }.sheet(isPresented: $showFilters) { filters }
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

private struct LiveReportCategoryView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let category: APISpendingCategoryReport
    var transactions: [APITransaction] { store.transactions.filter { category.transactionIDs.contains($0.id) } }
    var body: some View { List { Section { LabeledContent("Total", value: store.format(category.spendingMinor)); LabeledContent("Transactions", value: "\(transactions.count)"); LabeledContent("Average", value: store.format(transactions.isEmpty ? 0 : category.spendingMinor / Int64(transactions.count))) }; Section("Transactions") { ForEach(transactions) { LiveTransactionLink(transaction: $0) } } }.navigationTitle(category.categoryName) }
}

private struct LiveHouseholdView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { List { Section("Signed in") { LabeledContent("Member", value: session.profile?.displayName ?? ""); LabeledContent("Role", value: store.budget.effectivePermission.rawValue.capitalized) }; if store.budget.can("manage_allowances") { Section("Delegated budgets") { ForEach(store.householdMembers.filter { $0.role != "owner" && $0.isActive }) { member in NavigationLink { LiveDelegatedPolicyView(member: member) } label: { VStack(alignment: .leading) { Text(member.displayName); if let policy = store.delegatedBudgets.first(where: { $0.userID == member.userID }) { Text("Authority \(store.format(policy.authorityMinor)) · \(policy.allowReallocation ? "can reallocate" : "locked")").font(.caption).foregroundStyle(.secondary) } else { Text("Not configured").font(.caption).foregroundStyle(.secondary) } } } } } }; Section("Self-hosting") { LabeledContent("Server", value: session.serverURL?.host ?? ""); Label("Manual entry only — no bank connections", systemImage: "building.columns") } }.navigationTitle("Household").toolbar { Button("Done") { dismiss() } } } }
}

private struct LiveDelegatedPolicyView: View {
    @EnvironmentObject private var session: AppSession; @EnvironmentObject private var store: BudgetWorkspaceStore
    let member: APIHouseholdMember
    @State private var poolCategoryID = ""; @State private var authority = ""; @State private var allowCreation = true; @State private var allowReallocation = true; @State private var isSaving = false; @State private var errorMessage: String?
    private var categories: [APICategory] { store.categories.filter { $0.delegatedUserID == member.userID && !$0.isArchived } }
    var body: some View { Form { Section("Authority") { Picker("To assign category", selection: $poolCategoryID) { ForEach(categories) { Text($0.name).tag($0.id) } }; TextField("Total authority", text: $authority).keyboardType(.decimalPad); Toggle("Can create categories", isOn: $allowCreation); Toggle("Can move money", isOn: $allowReallocation) }; Section { Text("Authority is a hard household boundary. The member can organize only categories delegated to them, and cannot expose or move money into private family categories.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle(member.displayName).toolbar { Button("Save") { Task { await save() } }.disabled(poolCategoryID.isEmpty || parsed == nil || isSaving) }.onAppear { let existing = store.delegatedBudgets.first(where: { $0.userID == member.userID }); poolCategoryID = existing?.poolCategoryID ?? categories.first?.id ?? ""; authority = CurrencyText.editable(existing?.authorityMinor ?? 0, currencyCode: store.budget.currencyCode); allowCreation = existing?.allowCategoryCreation ?? true; allowReallocation = existing?.allowReallocation ?? true }.alert("Unable to save delegated budget", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
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
        TextField("Payee",text:$payee); TextField("Amount",text:$amount).keyboardType(.decimalPad); Toggle("Income / inflow",isOn:$isInflow); Picker("Account",selection:$accountID){ForEach(accounts.filter{!$0.isClosed}){Text($0.name).tag($0.id)}}; DatePicker("Date",selection:$date,displayedComponents:.date); Toggle("Split across categories",isOn:$isSplit).disabled(isInflow)
        if isSplit { Section("Splits") { ForEach($splitRows) { $row in Picker("Category",selection:$row.categoryID){Text("Select").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}};TextField("Split amount",text:$row.amount).keyboardType(.decimalPad);TextField("Split memo",text:$row.memo) }; Button("Add split",systemImage:"plus"){splitRows.append(.init())}; if let remaining { LabeledContent("Remaining",value:CurrencyText.editable(remaining,currencyCode:budget.currencyCode)).foregroundStyle(remaining == 0 ? Color.secondary : Color.red) } } } else if !isInflow { Picker("Category",selection:$categoryID){Text("Uncategorized").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}} }
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
