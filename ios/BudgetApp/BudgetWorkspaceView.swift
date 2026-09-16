import BudgetAPI
import SwiftUI
import Charts
import UniformTypeIdentifiers
import QuickLook
import PhotosUI
import AVFoundation
import UIKit

enum Theme {
    static let accent = Color(red: 0.10, green: 0.40, blue: 0.36)
    static let healthy = Color(red: 0.12, green: 0.48, blue: 0.33)
    static let attention = Color(red: 0.80, green: 0.48, blue: 0.08)
    static let danger = Color(red: 0.74, green: 0.18, blue: 0.20)
    static let projected = Color.indigo
}

struct PayeeSearchSelectionView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    let includeArchived: Bool
    let excludedID: String?
    let onSelect: (APIPayee) -> Void
    @State private var query = ""
    @State private var rows: [APIPayee] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var errorMessage: String?

    init(title: String = "Choose Payee", includeArchived: Bool = false, excludedID: String? = nil, onSelect: @escaping (APIPayee) -> Void) {
        self.title = title; self.includeArchived = includeArchived; self.excludedID = excludedID; self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty && !loading {
                    ContentUnavailableView(query.isEmpty ? "No recent payees" : "No matching payees", systemImage: "magnifyingglass", description: Text(query.isEmpty ? "Start typing to search saved payees." : "Filtering only selects an existing payee."))
                }
                ForEach(rows.filter { $0.id != excludedID }) { payee in
                    Button {
                        onSelect(payee); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(payee.displayName)
                            if !payee.aliases.isEmpty { Text(payee.aliases.map(\.displayName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("payee-search-result-\(payee.id)")
                }
                if nextCursor != nil {
                    Button("Load More") { Task { await load(reset: false) } }.disabled(loading).accessibilityIdentifier("payee-search-load-more")
                }
            }
            .overlay { if loading && rows.isEmpty { ProgressView() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search payees")
            .task(id: query) { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }; await load(reset: true) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Unable to search payees", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private func load(reset: Bool) async {
        if !reset && loading { return }
        let requestedQuery = query
        loading = true
        defer { if requestedQuery == query { loading = false } }
        do {
            let page = try await store.searchPayees(query: requestedQuery, includeArchived: includeArchived, limit: 20, cursor: reset ? nil : nextCursor)
            guard requestedQuery == query else { return }
            rows = reset ? page.items : rows + page.items
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch is CancellationError {
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct PayeeManagementView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showCreate = false
    @State private var query = ""
    @State private var rows: [APIPayee] = []
    @State private var nextCursor: String?
    @State private var loading = false
    var body: some View {
        List {
            if rows.isEmpty && !loading {
                ContentUnavailableView("No saved payees", systemImage: "person.text.rectangle", description: Text("Save payees for consistent transaction history and category suggestions."))
            } else {
                ForEach(rows) { payee in
                    NavigationLink { PayeeEditorView(payee: payee) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(payee.displayName)
                            Text("\(payee.transactionCount) transaction\(payee.transactionCount == 1 ? "" : "s") · \(store.format(payee.netAmountMinor)) net")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("payee-row-\(payee.id)")
                }
            }
            if nextCursor != nil { Button("Load More") { Task { await load(reset: false) } }.disabled(loading) }
        }
        .navigationTitle("Payees")
        .searchable(text: $query, prompt: "Search payees")
        .task(id: query) { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }; await load(reset: true) }
        .onAppear { Task { await load(reset: true) } }
        .toolbar { Button("Add Payee", systemImage: "plus") { showCreate = true }.accessibilityIdentifier("add-payee-action") }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load(reset: true) } }) { PayeeEditorView(payee: nil) }
        .overlay { if loading && rows.isEmpty { ProgressView() } }
    }
    private func load(reset: Bool) async { if !reset && loading { return }; let requestedQuery = query; loading = true; defer { if requestedQuery == query { loading = false } }; do { let page = try await store.searchPayees(query: requestedQuery, includeArchived: true, limit: 20, cursor: reset ? nil : nextCursor); guard requestedQuery == query else { return }; rows = reset ? page.items : rows + page.items; nextCursor = page.nextCursor } catch {} }
}

private struct PayeeEditorView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let payee: APIPayee?
    @State private var name: String
    @State private var categoryID: String
    @State private var isArchived: Bool
    @State private var mergeDestinationID = ""
    @State private var mergeDestinationName = ""
    @State private var showMergeSelector = false
    @State private var newAlias = ""
    @State private var aliases: [APIPayeeAlias]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(payee: APIPayee?) {
        self.payee = payee
        _name = State(initialValue: payee?.displayName ?? "")
        _categoryID = State(initialValue: payee?.defaultCategoryID ?? "")
        _isArchived = State(initialValue: payee?.isArchived ?? false)
        _aliases = State(initialValue: payee?.aliases ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payee") {
                    TextField("Name", text: $name).accessibilityIdentifier("payee-name")
                    Picker("Default category", selection: $categoryID) {
                        Text("No suggestion").tag("")
                        ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) }
                    }
                    if payee != nil { Toggle("Archived", isOn: $isArchived) }
                }
                if let payee {
                    Section("History") {
                        LabeledContent("Transactions", value: "\(payee.transactionCount)")
                        LabeledContent("Net amount", value: store.format(payee.netAmountMinor))
                    }
                    let history = store.transactions.filter { $0.payeeID == payee.id }
                    if !history.isEmpty {
                        Section("Recent transactions") {
                            ForEach(history.prefix(10)) { transaction in LiveTransactionLink(transaction: transaction) }
                        }
                    }
                    Section("Aliases") {
                        ForEach(aliases) { alias in
                            Text(alias.displayName)
                        }
                        .onDelete { offsets in Task { await deleteAliases(payee.id, offsets: offsets) } }
                        HStack {
                            TextField("New alias", text: $newAlias).accessibilityIdentifier("payee-alias-name")
                            Button("Add") { Task { await addAlias(payee.id) } }.disabled(newAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving).accessibilityIdentifier("add-payee-alias")
                        }
                        Text("Aliases match future payee names to this identity. They never rewrite transaction history or choose a category.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Merge") {
                        Button { showMergeSelector = true } label: { LabeledContent("Move history to", value: mergeDestinationName.isEmpty ? "Choose payee" : mergeDestinationName) }
                        Button("Merge Payee", role: .destructive) { Task { await merge(payee.id) } }.disabled(mergeDestinationID.isEmpty || isSaving)
                        Text("Transactions keep their identities and audit history. The source payee is archived.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(payee == nil ? "New Payee" : "Edit Payee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving) }
            }
            .alert("Unable to save payee", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showMergeSelector) { PayeeSearchSelectionView(title: "Merge Into", excludedID: payee?.id) { selected in mergeDestinationID = selected.id; mergeDestinationName = selected.displayName } }
        }
    }

    private func save() async {
        isSaving = true; defer { isSaving = false }
        do {
            if let payee { try await store.updatePayee(.init(payeeID: payee.id, displayName: name, isArchived: isArchived, defaultCategoryID: categoryID.isEmpty ? nil : categoryID)) }
            else { try await store.createPayee(.init(displayName: name, defaultCategoryID: categoryID.isEmpty ? nil : categoryID)) }
            dismiss()
        } catch is CancellationError {
            // A credential-generation change supersedes this snapshot with an immediate current-token load.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession can bridge structured task cancellation as URLError.cancelled.
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func merge(_ sourceID: String) async {
        isSaving = true; defer { isSaving = false }
        do { try await store.mergePayee(sourceID: sourceID, destinationID: mergeDestinationID); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
    private func addAlias(_ payeeID: String) async { isSaving = true; defer { isSaving = false }; do { try await store.createPayeeAlias(payeeID: payeeID, displayName: newAlias); newAlias = ""; await reloadAliases(payeeID) } catch { errorMessage = error.localizedDescription } }
    private func deleteAliases(_ payeeID: String, offsets: IndexSet) async { do { for offset in offsets { try await store.deletePayeeAlias(payeeID: payeeID, aliasID: aliases[offset].id) }; await reloadAliases(payeeID) } catch { errorMessage = error.localizedDescription } }
    private func reloadAliases(_ payeeID: String) async { do { let page = try await store.searchPayees(query: name, includeArchived: true, limit: 20); if let current = page.items.first(where: { $0.id == payeeID }) { aliases = current.aliases } } catch { errorMessage = error.localizedDescription } }
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

struct WorkspaceSnapshot {
    var accounts: [APIAccount]; var accountBalances: [String: APIAccountBalance]; var categories: [APICategory]; var groups: [APICategoryGroup]
    var transactions: [APITransaction]; var summary: APIMonthSummary?
    var payees: [APIPayee] = []
    var requests: [APIFinancialRequest]; var allowances: [APIAllowancePlan]
    var spending: APISpendingReport?; var income: APIIncomeSpendingReport?
    var delegated: APIDelegatedBudget?; var forecast: APIForecast?
    var members: [APIHouseholdMember]; var delegatedBudgets: [APIDelegatedBudget]
    var allocationOperations: [APIAllocationOperation] = []
    var targets: [APICategoryTarget] = []
    var schedules: [APIScheduledTransaction] = []
}

struct WorkspaceReportQuery {
    let start: Date; let end: Date; let accountID: String; let categoryID: String
    let categoryGroup: String; let payee: String; let memberID: String
    let transactionType: String; let cleared: String; let includeTracking: Bool
}

@MainActor
protocol WorkspaceDataSource: AnyObject {
    var budget: APIBudget { get }
    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot
}

@MainActor
protocol WorkspaceCommandRepository: AccountCommandRepository, PlanningCommandRepository, TransactionCommandRepository, TransactionBrowserRepository, ScheduleCommandRepository, PayeeCommandRepository {
    func createCategory(groupID: String, groupName: String, newGroupName: String, name: String, delegatedUserID: String?) async throws
    func createGroup(name: String) async throws
    func createRequest(_ value: APIFinancialRequestCreate) async throws
    func updateCategory(id: String, value: APICategoryUpdate, groupName: String?, existingDelegatedUserID: String?, delegatedUserID: String?) async throws
    func updateGroup(id: String, currentName: String?, value: APICategoryGroupUpdate) async throws
    func deleteGroup(id: String, currentName: String?) async throws
    func deleteCategory(id: String) async throws
    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws
    func deleteTarget(categoryID: String) async throws
    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws
    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview
    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws
    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws
}

@MainActor
final class DemoWorkspaceDataSource: WorkspaceDataSource {
    let demo: DemoStore
    private var attachmentData: [String: Data] = [:]
    let budget: APIBudget

    init(fresh: Bool = false) {
        let store = DemoStore()
        if fresh || ProcessInfo.processInfo.arguments.contains("--demo-fresh-budget") {
            store.accounts = []
            store.categories = []
            store.transactions = []
            store.schedules = []
            store.requests = []
            store.allowances = []
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
        let accountRows: [APIAccount] = try decode(visibleAccounts.map { ["id": $0.id, "budget_id": budget.id, "name": $0.name, "account_type": $0.kind.rawValue, "is_on_budget": $0.isOnBudget, "is_closed": false, "reconciled_balance_minor": $0.cleared, "payment_category_id": NSNull()] })
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
            return ["id": item.id, "account_id": item.accountID, "category_id": ids.count == 1 ? ids[0] : NSNull(), "payee_id": demo.payees.first(where: { $0.name == item.payee })?.id ?? NSNull(), "amount_minor": item.amount, "occurred_on": dateFormatter.string(from: item.date), "payee_name": item.payee, "memo": item.memo, "is_cleared": item.cleared, "is_reconciled": item.reconciled, "created_by_user_id": demo.persona.rawValue.lowercased(), "transfer_id": item.transferID.map { $0 as Any } ?? NSNull(), "scheduled_transaction_id": NSNull(), "flag": item.flag.map { $0 as Any } ?? NSNull(), "tags": item.tags, "attachment_metadata": item.attachmentName.map { [["name": $0]] } ?? [], "status": item.status, "void_reason": item.voidReason ?? NSNull(), "reversal_of_transaction_id": item.reversalOfTransactionID ?? NSNull(), "reversal_transaction_id": item.reversalTransactionID ?? NSNull(), "splits": splits]
        })
        let payeeRows: [APIPayee] = try decode(demo.payees.filter { !$0.isArchived }.map { item in
            let history = demo.visibleTransactions.filter { $0.payee == item.name }
            return ["id": item.id, "household_id": budget.householdID, "display_name": item.name, "is_archived": item.isArchived,
                    "merged_into_payee_id": NSNull(), "default_category_id": item.defaultCategoryID ?? NSNull(),
                    "transaction_count": history.count, "net_amount_minor": history.reduce(Int64(0)) { $0 + $1.amount }, "aliases": item.aliases.enumerated().map { ["id": "\(item.id)-alias-\($0.offset)", "display_name": $0.element] }] as [String: Any]
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
        let spendingRows: [[String: Any]] = visibleCategories.compactMap { category in
            let contributing = included.filter { $0.transferID == nil && $0.amount != 0 && $0.categoryIDs.contains(category.id) }
            let total = contributing.reduce(Int64(0)) { $0 - (demo.canonicalCategoryAmounts(for: $1)[category.id] ?? 0) }
            return total <= 0 ? nil : ["category_id": category.id, "category_name": category.name, "category_group": category.group, "spending_minor": total, "transaction_ids": contributing.map(\.id)]
        }
        let spending: APISpendingReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "total_spending_minor": spendingRows.reduce(Int64(0)) { $0 + ($1["spending_minor"] as? Int64 ?? 0) }, "categories": spendingRows])
        let reportIncome = included.filter { $0.transferID == nil && $0.amount > 0 && $0.categoryIDs.isEmpty }
        let reportSpending = included.filter { $0.transferID == nil && !$0.categoryIDs.isEmpty }
        let incomeValue = reportIncome.reduce(Int64(0)) { $0 + $1.amount }
        let spendingValue = spendingRows.reduce(Int64(0)) { $0 + ($1["spending_minor"] as? Int64 ?? 0) }
        var periodRows: [[String: Any]] = []
        var reportMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: start))!
        while reportMonth <= report.end {
            let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: reportMonth)!
            let periodStart = max(start, reportMonth), periodEnd = min(report.end, Calendar.current.date(byAdding: .day, value: -1, to: nextMonth)!)
            let periodIncome = reportIncome.filter { $0.date >= periodStart && $0.date <= periodEnd }
            let periodSpending = reportSpending.filter { $0.date >= periodStart && $0.date <= periodEnd }
            let periodIncomeMinor = periodIncome.reduce(Int64(0)) { $0 + $1.amount }
            let periodSpendingMinor = periodSpending.reduce(Int64(0)) { result, item in result - demo.canonicalCategoryAmounts(for: item).values.reduce(0, +) }
            periodRows.append(["period_start": dateFormatter.string(from: periodStart), "period_end": dateFormatter.string(from: periodEnd), "income_minor": periodIncomeMinor, "spending_minor": periodSpendingMinor, "difference_minor": periodIncomeMinor - periodSpendingMinor, "income_transaction_ids": periodIncome.map { $0.id }, "spending_transaction_ids": periodSpending.map { $0.id }])
            reportMonth = nextMonth
        }
        let income: APIIncomeSpendingReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "income_minor": incomeValue, "spending_minor": spendingValue, "difference_minor": incomeValue - spendingValue, "savings_rate": incomeValue > 0 ? Double(incomeValue - spendingValue) / Double(incomeValue) : NSNull(), "income_transaction_ids": reportIncome.map(\.id), "spending_transaction_ids": reportSpending.map(\.id), "periods": periodRows])
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
        let onBudgetAccounts = visibleAccounts.filter(\.isOnBudget)
        let actualTotal = onBudgetAccounts.reduce(Int64(0)) { $0 + $1.balance }, projectedTotal = onBudgetAccounts.reduce(Int64(0)) { $0 + (projected[$1.id] ?? $1.balance) }
        let demoForecast: APIForecast = try decode(["as_of": BudgetWorkspaceStore.dateString(forecastStart), "through": BudgetWorkspaceStore.dateString(forecastThrough), "currency_code": budget.currencyCode, "actual_total_on_budget_minor": actualTotal, "projected_total_on_budget_minor": projectedTotal, "lowest_projected_total_minor": min(actualTotal, projectedTotal), "accounts": forecastAccounts, "occurrences": occurrenceRows])
        return WorkspaceSnapshot(accounts: accountRows, accountBalances: Dictionary(uniqueKeysWithValues: accountBalanceRows.map { ($0.accountID, $0) }), categories: categoryRows, groups: groupRows, transactions: transactionRows, summary: summary, payees: payeeRows, requests: requestRows, allowances: [], spending: spending, income: income, delegated: delegated, forecast: demoForecast, members: [], delegatedBudgets: [], allocationOperations: allocationOperations, targets: targetRows, schedules: scheduleRows)
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
}

extension DemoWorkspaceDataSource: WorkspaceCommandRepository {
    func browseTransactions(query: APITransactionQuery) async throws -> APITransactionPage {
        let report = WorkspaceReportQuery(start: .distantPast, end: .distantFuture, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", includeTracking: true)
        var rows = try await snapshot(planMonth: Date(), report: report).transactions
        let text = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = rows.filter { item in
            let categoryIDs = Set(([item.categoryID].compactMap { $0 }) + item.splits.map(\.categoryID))
            return (text.isEmpty || item.payeeName.localizedCaseInsensitiveContains(text) || item.memo.localizedCaseInsensitiveContains(text) || (item.flag ?? "").localizedCaseInsensitiveContains(text) || (item.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(text) }))
                && (query.accountIDs.isEmpty || query.accountIDs.contains(item.accountID))
                && (query.categoryIDs.isEmpty || !categoryIDs.isDisjoint(with: query.categoryIDs))
                && (query.payeeIDs.isEmpty || item.payeeID.map(query.payeeIDs.contains) == true)
                && (query.startDate == nil || item.occurredOn >= query.startDate!)
                && (query.endDate == nil || item.occurredOn <= query.endDate!)
                && (query.minimumAmountMinor == nil || item.amountMinor >= query.minimumAmountMinor!)
                && (query.maximumAmountMinor == nil || item.amountMinor <= query.maximumAmountMinor!)
                && (query.lifecycleStatuses.isEmpty || query.lifecycleStatuses.contains(item.status ?? "posted"))
                && (query.cleared == nil || item.isCleared == query.cleared!)
                && (query.reconciled == nil || item.isReconciled == query.reconciled!)
                && (query.flags.isEmpty || item.flag.map(query.flags.contains) == true)
                && (query.tags.isEmpty || !(Set(item.tags ?? []).isDisjoint(with: query.tags)))
                && (query.actorUserIDs.isEmpty || item.createdByUserID.map(query.actorUserIDs.contains) == true)
                && (query.isTransfer == nil || (item.transferID != nil) == query.isTransfer!)
                && (query.isScheduledRealization == nil || (item.scheduledTransactionID != nil) == query.isScheduledRealization!)
                && Self.matchesType(item, query.transactionType, categoryIDs: categoryIDs)
        }
        switch query.sort {
        case "date_asc": rows.sort { ($0.occurredOn, $0.createdAt ?? "", $0.id) < ($1.occurredOn, $1.createdAt ?? "", $1.id) }
        case "amount_desc": rows.sort { ($0.amountMinor, $0.id) > ($1.amountMinor, $1.id) }
        case "amount_asc": rows.sort { ($0.amountMinor, $0.id) < ($1.amountMinor, $1.id) }
        case "payee_asc": rows.sort { ($0.payeeName.localizedLowercase, $0.id) < ($1.payeeName.localizedLowercase, $1.id) }
        default: rows.sort { ($0.occurredOn, $0.createdAt ?? "", $0.id) > ($1.occurredOn, $1.createdAt ?? "", $1.id) }
        }
        let start = query.cursor.flatMap { cursor in rows.firstIndex(where: { $0.id == cursor }).map { $0 + 1 } } ?? 0
        let end = min(start + query.limit, rows.count)
        let page = start < end ? Array(rows[start..<end]) : []
        return APITransactionPage(items: page, nextCursor: end < rows.count ? page.last?.id : nil, totalCount: rows.count)
    }
    private static func matchesType(_ item: APITransaction, _ type: String?, categoryIDs: Set<String>) -> Bool {
        switch type {
        case "transfer": return item.transferID != nil
        case "income": return item.transferID == nil && item.amountMinor > 0 && categoryIDs.isEmpty
        case "spending": return item.transferID == nil && item.amountMinor < 0 && !categoryIDs.isEmpty
        case "refund": return item.transferID == nil && item.amountMinor > 0 && !categoryIDs.isEmpty
        default: return true
        }
    }
    func searchPayees(query: String, includeArchived: Bool, limit: Int, cursor: String?) async throws -> APIPayeePage {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [APIPayee] = try decode(demo.payees.filter { item in
            (includeArchived || !item.isArchived) && (needle.isEmpty || item.name.localizedCaseInsensitiveContains(needle) || item.aliases.contains { $0.localizedCaseInsensitiveContains(needle) })
        }.map { item in
            let history = demo.visibleTransactions.filter { $0.payee == item.name }
            return ["id": item.id, "household_id": budget.householdID, "display_name": item.name, "is_archived": item.isArchived,
                    "merged_into_payee_id": NSNull(), "default_category_id": item.defaultCategoryID ?? NSNull(),
                    "transaction_count": history.count, "net_amount_minor": history.reduce(Int64(0)) { $0 + $1.amount }, "aliases": item.aliases.enumerated().map { ["id": "\(item.id)-alias-\($0.offset)", "display_name": $0.element] }] as [String: Any]
        })
        values.sort { lhs, rhs in lhs.transactionCount == rhs.transactionCount ? lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending : lhs.transactionCount > rhs.transactionCount }
        let start = Int(cursor ?? "") ?? 0
        let end = min(start + limit, values.count)
        return APIPayeePage(items: start < end ? Array(values[start..<end]) : [], nextCursor: end < values.count ? String(end) : nil)
    }
    func createPayee(_ operation: CreatePayeeOperation) async throws {
        let name = operation.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo.payees.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw workspaceRepositoryError("A payee with this name already exists.") }
        demo.payees.append(.init(id: DemoStore.payeeID(name), name: name, defaultCategoryID: operation.defaultCategoryID))
    }
    func updatePayee(_ operation: UpdatePayeeOperation) async throws {
        guard let index = demo.payees.firstIndex(where: { $0.id == operation.payeeID }) else { throw workspaceRepositoryError("Payee not found.") }
        let old = demo.payees[index].name; demo.payees[index].name = operation.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        demo.payees[index].isArchived = operation.isArchived; demo.payees[index].defaultCategoryID = operation.defaultCategoryID
        for transactionIndex in demo.transactions.indices where demo.transactions[transactionIndex].payee == old { demo.transactions[transactionIndex].payee = demo.payees[index].name }
    }
    func mergePayee(sourceID: String, destinationID: String) async throws {
        guard let source = demo.payees.first(where: { $0.id == sourceID }), let destination = demo.payees.first(where: { $0.id == destinationID }) else { throw workspaceRepositoryError("Payee not found.") }
        for index in demo.transactions.indices where demo.transactions[index].payee == source.name { demo.transactions[index].payee = destination.name }
        demo.payees.removeAll { $0.id == sourceID }
    }
    func createPayeeAlias(payeeID: String, displayName: String) async throws {
        guard let index = demo.payees.firstIndex(where: { $0.id == payeeID }) else { throw workspaceRepositoryError("Payee not found.") }
        let alias = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo.payees.flatMap(\.aliases).contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) else { throw workspaceRepositoryError("This alias is already in use.") }
        demo.payees[index].aliases.append(alias)
    }
    func deletePayeeAlias(payeeID: String, aliasID: String) async throws {
        guard let index = demo.payees.firstIndex(where: { $0.id == payeeID }), let offset = Int(aliasID.split(separator: "-").last ?? "") else { throw workspaceRepositoryError("Alias not found.") }
        guard demo.payees[index].aliases.indices.contains(offset) else { throw workspaceRepositoryError("Alias not found.") }
        demo.payees[index].aliases.remove(at: offset)
    }
    func recordTransaction(_ operation: RecordTransactionOperation) async throws {
        guard demo.recordCanonicalTransaction(operation) else { throw workspaceRepositoryError(demo.errorMessage) }
    }
    func updateTransaction(id: String, operation: RecordTransactionOperation) async throws {
        guard demo.updateCanonicalTransaction(id: id, operation: operation) else { throw workspaceRepositoryError(demo.errorMessage) }
    }

    func deleteTransaction(id: String) async throws { guard demo.deleteTransaction(id: id) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func duplicateTransaction(id: String, occurredOn: String) async throws {
        guard let source = demo.transactions.first(where: { $0.id == id }), source.transferID == nil, !source.scheduled else { throw workspaceRepositoryError("This system-linked transaction must be recreated through its specialized workflow") }
        let amounts = demo.canonicalCategoryAmounts(for: source)
        let singleCategory = amounts.count == 1 ? amounts.keys.first : nil
        let splits = amounts.count > 1 ? amounts.keys.sorted().map { TransactionSplitOperation(categoryID: $0, amountMinor: amounts[$0]!, memo: "") } : []
        let operation = RecordTransactionOperation(accountID: source.accountID, categoryID: singleCategory, amountMinor: source.amount, occurredOn: occurredOn, payeeName: source.payee, payeeID: demo.payees.first(where: { $0.name == source.payee })?.id, memo: source.memo, isCleared: false, splits: splits, flag: source.flag, tags: source.tags, attachmentMetadata: [])
        guard demo.recordCanonicalTransaction(operation) else { throw workspaceRepositoryError(demo.errorMessage) }
    }
    func voidTransaction(id: String, reason: String) async throws {
        guard let source = demo.transactions.first(where: { $0.id == id }), source.status == "posted", source.transferID == nil, !source.reconciled else { throw workspaceRepositoryError("Only an unreconciled posted transaction can be voided") }
        let amounts = demo.canonicalCategoryAmounts(for: source)
        let splits = amounts.count > 1 ? amounts.keys.sorted().map { TransactionSplitOperation(categoryID: $0, amountMinor: -amounts[$0]!, memo: "") } : []
        let operation = RecordTransactionOperation(accountID: source.accountID, categoryID: amounts.count == 1 ? amounts.keys.first : nil, amountMinor: -source.amount, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: "Reversal: \(source.payee)", memo: reason.isEmpty ? "Void reversal." : "Void reversal. \(reason)", isCleared: false, splits: splits, flag: source.flag, tags: source.tags, attachmentMetadata: [])
        let reversalID = UUID().uuidString
        guard demo.recordCanonicalTransaction(operation, id: reversalID),
              let reversalIndex = demo.transactions.firstIndex(where: { $0.id == reversalID }),
              let originalIndex = demo.transactions.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError(demo.errorMessage) }
        demo.transactions[reversalIndex].status = "reversal"
        demo.transactions[reversalIndex].reversalOfTransactionID = id
        demo.transactions[originalIndex].status = "voided"
        demo.transactions[originalIndex].voidReason = reason.isEmpty ? nil : reason
        demo.transactions[originalIndex].reversalTransactionID = reversalID
    }
    func createScheduleFromTransaction(id: String, operation: MakeRecurringOperation) async throws {
        guard let source = demo.transactions.first(where: { $0.id == id }), source.status == "posted", source.transferID == nil, source.categoryIDs.count <= 1 else { throw workspaceRepositoryError("This transaction cannot be used as a recurring template") }
        demo.schedules.append(.init(id: UUID().uuidString, accountID: source.accountID, destinationAccountID: nil, categoryID: source.categoryIDs.first, name: source.payee, amount: source.amount, nextDate: operation.nextDate, recurrenceUnit: operation.recurrenceUnit, intervalCount: operation.intervalCount, memo: source.memo, isActive: true))
    }
    func transactionAttachments(id: String) async throws -> [APITransactionAttachment] {
        guard let transaction = demo.transactions.first(where: { $0.id == id }) else { throw workspaceRepositoryError("Transaction not found") }
        guard let name = transaction.attachmentName else { return [] }
        let data = attachmentData[id] ?? Data()
        return [try JSONDecoder().decode(APITransactionAttachment.self, from: JSONSerialization.data(withJSONObject: ["id": "demo-attachment-\(id)", "transaction_id": id, "filename": name, "content_type": "application/pdf", "byte_count": data.count, "sha256": "demo", "created_at": "2026-09-14T00:00:00Z", "detached_at": NSNull()]))]
    }
    func uploadTransactionAttachment(id: String, filename: String, contentType: String, data: Data) async throws {
        guard let index = demo.transactions.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Transaction not found") }
        demo.transactions[index].attachmentName = filename
        attachmentData[id] = data
    }
    func downloadTransactionAttachment(transactionID: String, attachmentID: String) async throws -> Data { attachmentData[transactionID] ?? Data() }
    func detachTransactionAttachment(transactionID: String, attachmentID: String) async throws {
        guard let index = demo.transactions.firstIndex(where: { $0.id == transactionID }) else { throw workspaceRepositoryError("Transaction not found") }
        demo.transactions[index].attachmentName = nil
        attachmentData.removeValue(forKey: transactionID)
    }
    func bulkUpdateTransactions(_ update: APITransactionBulkUpdate) async throws {
        guard update.transactionIDs.allSatisfy({ id in demo.transactions.contains(where: { $0.id == id && !$0.reconciled && $0.transferID == nil && !$0.scheduled && !["Starting Balance", "Reconciliation adjustment"].contains($0.payee) }) }) else { throw workspaceRepositoryError("System-linked or reconciled transactions cannot be changed in bulk") }
        for id in update.transactionIDs {
            guard let index = demo.transactions.firstIndex(where: { $0.id == id }) else { continue }
            switch update.action {
            case "set_cleared": demo.transactions[index].cleared = update.cleared ?? false
            case "set_flag": demo.transactions[index].flag = update.flag
            case "add_tags": demo.transactions[index].tags = Array(Set(demo.transactions[index].tags + (update.tags ?? []))).sorted()
            case "remove_tags": demo.transactions[index].tags.removeAll(where: Set(update.tags ?? []).contains)
            default: throw workspaceRepositoryError("Unsupported bulk action")
            }
        }
    }
    func transferMoney(_ operation: TransferMoneyOperation) async throws { guard demo.transfer(amount: operation.amountMinor, from: operation.sourceAccountID, to: operation.destinationAccountID, memo: operation.memo, cleared: operation.isCleared, date: BudgetWorkspaceStore.parseDate(operation.occurredOn)) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws { guard demo.updateTransfer(id: id, amount: operation.amountMinor, from: operation.sourceAccountID, to: operation.destinationAccountID, memo: operation.memo, cleared: operation.isCleared, date: BudgetWorkspaceStore.parseDate(operation.occurredOn)) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func deleteTransfer(id: String) async throws { guard demo.deleteTransfer(id: id) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func reconcileAccount(_ operation: ReconcileAccountOperation) async throws { guard demo.reconcile(accountID: operation.accountID, statementBalance: operation.statementBalanceMinor) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func assignMoney(_ operation: AssignMoneyOperation) async throws {
        guard !demo.isRestricted, let index = demo.categories.firstIndex(where: { $0.id == operation.categoryID }) else { throw workspaceRepositoryError("Delegated members allocate from their own pool by moving money.") }
        let delta = operation.assignedMinor - demo.categories[index].assigned
        guard delta <= demo.readyToAssign else { throw workspaceRepositoryError("Not enough real money to assign.") }
        demo.categories[index].assigned += delta; demo.categories[index].available += delta; demo.setUnassigned(demo.readyToAssign - delta)
    }
    func moveMoney(_ operation: MoveMoneyOperation) async throws { guard demo.move(amount: operation.amountMinor, from: operation.sourceCategoryID, to: operation.destinationCategoryID) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func createCategory(groupID: String, groupName: String, newGroupName: String, name: String, delegatedUserID: String?) async throws { guard demo.createCategory(name: name, group: groupName.isEmpty ? newGroupName : groupName) else { throw workspaceRepositoryError(demo.errorMessage) } }
    func createGroup(name: String) async throws { if !demo.groupOrder.contains(name) { demo.groupOrder.append(name) } }
    func createAccount(_ operation: CreateAccountOperation) async throws { demo.createAccount(name: operation.name, type: operation.kind, isOnBudget: operation.isOnBudget, startingBalance: operation.openingBalanceMinor) }
    func updateAccount(_ operation: UpdateAccountMetadataOperation) async throws {
        guard demo.updateAccount(id: operation.accountID, name: operation.name, type: operation.kind) else { throw workspaceRepositoryError("Account not found.") }
    }
    func createRequest(_ value: APIFinancialRequestCreate) async throws { demo.requests.insert(.init(id: UUID().uuidString, member: demo.persona, amount: value.requestedAmountMinor, categoryID: value.destinationCategoryID, reason: value.reason, status: "Pending", date: .demo(monthsAgo: 0, day: 30)), at: 0) }
    func updateCategory(id: String, value: APICategoryUpdate, groupName: String?, existingDelegatedUserID: String?, delegatedUserID: String?) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Category not found.") }
        let targetGroup = groupName ?? demo.categories[index].group
        guard !demo.categories.contains(where: { $0.id != id && $0.group == targetGroup && normalizedCategoryName($0.name) == normalizedCategoryName(value.name) }) else { throw workspaceRepositoryError("A category with this name already exists in the group.") }
        demo.categories[index].name = value.name.trimmingCharacters(in: .whitespacesAndNewlines); demo.categories[index].group = targetGroup; demo.categories[index].isHidden = value.isArchived
    }
    func updateGroup(id: String, currentName: String?, value: APICategoryGroupUpdate) async throws {
        guard let currentName else { throw workspaceRepositoryError("Category group not found.") }
        for index in demo.categories.indices where demo.categories[index].group == currentName { demo.categories[index].group = value.name }
        if let index = demo.groupOrder.firstIndex(of: currentName) { demo.groupOrder[index] = value.name; demo.groupOrder.remove(at: index); demo.groupOrder.insert(value.name, at: min(max(value.sortOrder, 0), demo.groupOrder.count)) }
        demo.archivedGroups.remove(currentName); if value.isArchived { demo.archivedGroups.insert(value.name) }
    }
    func deleteGroup(id: String, currentName: String?) async throws {
        guard let currentName else { throw workspaceRepositoryError("Category group not found.") }
        guard !demo.categories.contains(where: { $0.group == currentName }) else { throw workspaceRepositoryError("Move or archive every category before deleting this group") }
        demo.groupOrder.removeAll { $0 == currentName }
    }
    func deleteCategory(id: String) async throws { guard !demo.transactions.contains(where: { $0.categoryIDs.contains(id) }) else { throw workspaceRepositoryError("This category has financial history. Archive it to preserve the audit trail") }; demo.categories.removeAll { $0.id == id } }
    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == categoryID }) else { throw workspaceRepositoryError("Category not found.") }
        demo.categories[index].target = value.targetAmountMinor; demo.categories[index].targetDate = value.targetDate; demo.categories[index].targetType = value.targetType; demo.categories[index].targetRecurrenceMonths = value.recurrenceMonths; demo.categories[index].targetMinimumContribution = value.minimumContributionMinor; demo.categories[index].targetPriority = value.priority; demo.categories[index].targetIsActive = value.isActive
    }
    func deleteTarget(categoryID: String) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == categoryID }) else { throw workspaceRepositoryError("Category not found.") }
        demo.categories[index].target = nil; demo.categories[index].targetDate = nil; demo.categories[index].targetType = "savings_balance"; demo.categories[index].targetRecurrenceMonths = nil; demo.categories[index].targetMinimumContribution = 0; demo.categories[index].targetPriority = 50; demo.categories[index].targetIsActive = true
    }
    func createSchedule(_ operation: ScheduleOperation) async throws { demo.schedules.append(.init(id: UUID().uuidString, accountID: operation.accountID, destinationAccountID: operation.destinationAccountID, categoryID: operation.categoryID, name: operation.name, amount: operation.amountMinor, nextDate: operation.nextDate, recurrenceUnit: operation.recurrenceUnit, intervalCount: operation.intervalCount, memo: operation.memo, isActive: operation.isActive)) }
    func updateSchedule(id: String, operation: ScheduleOperation) async throws {
        guard let index = demo.schedules.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Schedule not found.") }
        demo.schedules[index].accountID = operation.accountID; demo.schedules[index].destinationAccountID = operation.destinationAccountID; demo.schedules[index].categoryID = operation.categoryID; demo.schedules[index].name = operation.name; demo.schedules[index].amount = operation.amountMinor; demo.schedules[index].nextDate = operation.nextDate; demo.schedules[index].recurrenceUnit = operation.recurrenceUnit; demo.schedules[index].intervalCount = operation.intervalCount; demo.schedules[index].memo = operation.memo; demo.schedules[index].isActive = operation.isActive
    }
    func deleteSchedule(id: String) async throws { demo.schedules.removeAll { $0.id == id } }
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation {
        guard let index = demo.schedules.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Schedule not found.") }
        let item = demo.schedules[index]; guard item.isActive else { throw workspaceRepositoryError("Scheduled transaction is inactive") }
        let due = BudgetWorkspaceStore.parseDate(item.nextDate); guard Calendar.current.startOfDay(for: due) <= Calendar.current.startOfDay(for: Date()) else { throw workspaceRepositoryError("This scheduled transaction is not due yet") }
        let before = Set(demo.transactions.map(\.id))
        if let destination = item.destinationAccountID { guard demo.transfer(amount: item.amount, from: item.accountID, to: destination, memo: item.memo, cleared: false, date: due) else { throw workspaceRepositoryError(demo.errorMessage) } }
        else {
            let operation = RecordTransactionOperation(accountID: item.accountID, categoryID: item.categoryID, amountMinor: item.amount, occurredOn: item.nextDate, payeeName: item.name, memo: item.memo, isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])
            guard demo.recordCanonicalTransaction(operation) else { throw workspaceRepositoryError(demo.errorMessage) }
        }
        let transactionIDs = demo.transactions.map(\.id).filter { !before.contains($0) }
        let next = BudgetWorkspaceStore.nextScheduledDate(from: due, unit: item.recurrenceUnit, interval: item.intervalCount)
        demo.schedules[index].lastRealizedOn = item.nextDate; demo.schedules[index].isActive = next != nil; if let next { demo.schedules[index].nextDate = BudgetWorkspaceStore.dateString(next) }
        return ScheduledRealizationObservation(scheduleID: id, transactionIDs: transactionIDs, realizedOn: item.nextDate, nextDate: next.map(BudgetWorkspaceStore.dateString), isActive: next != nil, lastRealizedOn: item.nextDate)
    }
    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws { if decision == "approve", let amount { demo.approve(id, amount: amount) } else if let index = demo.requests.firstIndex(where: { $0.id == id }) { demo.requests[index].status = decision == "reject" ? "Rejected" : "Changes requested" } }
    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview {
        var remaining = max(demo.readyToAssign, 0); var rows: [[String: Any]] = []
        for category in demo.visibleCategories where remaining > 0 { let needed = max((category.target ?? 0) - category.available, 0); let amount = min(needed, remaining); if amount > 0 { rows.append(["category_id": category.id, "category_name": category.name, "amount_minor": amount, "before_available_minor": category.available, "after_available_minor": category.available + amount]); remaining -= amount } }
        let proposed = max(demo.readyToAssign, 0) - remaining
        return try JSONDecoder().decode(APISmartFundingPreview.self, from: JSONSerialization.data(withJSONObject: ["month": month, "currency_code": "USD", "before_ready_to_assign_minor": demo.readyToAssign, "proposed_minor": proposed, "after_ready_to_assign_minor": demo.readyToAssign - proposed, "allocation_version": 1, "proposals": rows]))
    }
    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws { for proposal in preview.proposals { demo.assign(amount: proposal.amountMinor, to: proposal.categoryID) } }
    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws { throw workspaceRepositoryError("Owner policy editing is demonstrated in live mode; use a delegated demo persona to verify the member experience.") }
}

private func workspaceRepositoryError(_ message: String?) -> NSError { NSError(domain: "BudgetWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "Unable to complete the change."]) }

@MainActor
final class LiveWorkspaceCredentials {
    typealias Resolver = @MainActor (_ forceRefresh: Bool) async throws -> (URL, String)
    private(set) var serverURL: URL
    private(set) var token: String
    let clientFactory: (URL) throws -> APIClient
    private var resolver: Resolver?

    init(serverURL: URL, token: String, clientFactory: @escaping (URL) throws -> APIClient) {
        self.serverURL = serverURL
        self.token = token
        self.clientFactory = clientFactory
    }

    func update(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    func bind(_ resolver: @escaping Resolver) { self.resolver = resolver }

    func prepare(forceRefresh: Bool = false) async throws {
        guard let resolver else { return }
        let (serverURL, token) = try await resolver(forceRefresh)
        update(serverURL: serverURL, token: token)
    }

    func client() throws -> APIClient { try clientFactory(serverURL) }
}

@MainActor
private final class LiveWorkspaceCommandRepository: WorkspaceCommandRepository {
    let budget: APIBudget
    private let credentials: LiveWorkspaceCredentials
    private var token: String { credentials.token }
    private var client: APIClient { get throws { try credentials.client() } }
    init(budget: APIBudget, credentials: LiveWorkspaceCredentials) { self.budget = budget; self.credentials = credentials }

    func browseTransactions(query: APITransactionQuery) async throws -> APITransactionPage { try await credentials.prepare(); return try await client.searchTransactions(budgetID: budget.id, query: query, token: token) }
    func searchPayees(query: String, includeArchived: Bool, limit: Int, cursor: String?) async throws -> APIPayeePage { try await credentials.prepare(); return try await client.searchPayees(budgetID: budget.id, query: query, includeArchived: includeArchived, limit: limit, cursor: cursor, token: token) }

    func createPayee(_ operation: CreatePayeeOperation) async throws { try await credentials.prepare(); _ = try await client.createPayee(budgetID: budget.id, payee: APIPayeeCreate(displayName: operation.displayName, defaultCategoryID: operation.defaultCategoryID), token: token) }
    func updatePayee(_ operation: UpdatePayeeOperation) async throws { try await credentials.prepare(); _ = try await client.updatePayee(budgetID: budget.id, payeeID: operation.payeeID, payee: APIPayeeUpdate(displayName: operation.displayName, isArchived: operation.isArchived, defaultCategoryID: operation.defaultCategoryID), token: token) }
    func mergePayee(sourceID: String, destinationID: String) async throws { try await credentials.prepare(); _ = try await client.mergePayee(budgetID: budget.id, payeeID: sourceID, destinationPayeeID: destinationID, token: token) }
    func createPayeeAlias(payeeID: String, displayName: String) async throws { try await credentials.prepare(); _ = try await client.createPayeeAlias(budgetID: budget.id, payeeID: payeeID, displayName: displayName, token: token) }
    func deletePayeeAlias(payeeID: String, aliasID: String) async throws { try await credentials.prepare(); try await client.deletePayeeAlias(budgetID: budget.id, payeeID: payeeID, aliasID: aliasID, token: token) }

    func recordTransaction(_ operation: RecordTransactionOperation) async throws { try await credentials.prepare(); _ = try await client.createTransaction(budgetID: budget.id, transaction: operation.apiValue, token: token) }
    func updateTransaction(id: String, operation: RecordTransactionOperation) async throws { try await credentials.prepare(); _ = try await client.updateTransaction(budgetID: budget.id, transactionID: id, transaction: operation.apiValue, token: token) }
    func deleteTransaction(id: String) async throws { try await credentials.prepare(); try await client.deleteTransaction(budgetID: budget.id, transactionID: id, token: token) }
    func duplicateTransaction(id: String, occurredOn: String) async throws { try await credentials.prepare(); _ = try await client.duplicateTransaction(budgetID: budget.id, transactionID: id, occurredOn: occurredOn, token: token) }
    func voidTransaction(id: String, reason: String) async throws { try await credentials.prepare(); _ = try await client.voidTransaction(budgetID: budget.id, transactionID: id, reason: reason, token: token) }
    func createScheduleFromTransaction(id: String, operation: MakeRecurringOperation) async throws { try await credentials.prepare(); _ = try await client.createScheduleFromTransaction(budgetID: budget.id, transactionID: id, request: .init(recurrenceUnit: operation.recurrenceUnit, intervalCount: operation.intervalCount, nextDate: operation.nextDate), token: token) }
    func transactionAttachments(id: String) async throws -> [APITransactionAttachment] { try await credentials.prepare(); return try await client.transactionAttachments(budgetID: budget.id, transactionID: id, token: token) }
    func uploadTransactionAttachment(id: String, filename: String, contentType: String, data: Data) async throws { try await credentials.prepare(); _ = try await client.uploadTransactionAttachment(budgetID: budget.id, transactionID: id, filename: filename, contentType: contentType, data: data, token: token) }
    func downloadTransactionAttachment(transactionID: String, attachmentID: String) async throws -> Data { try await credentials.prepare(); return try await client.downloadTransactionAttachment(budgetID: budget.id, transactionID: transactionID, attachmentID: attachmentID, token: token) }
    func detachTransactionAttachment(transactionID: String, attachmentID: String) async throws { try await credentials.prepare(); try await client.detachTransactionAttachment(budgetID: budget.id, transactionID: transactionID, attachmentID: attachmentID, token: token) }
    func bulkUpdateTransactions(_ update: APITransactionBulkUpdate) async throws { try await credentials.prepare(); _ = try await client.bulkUpdateTransactions(budgetID: budget.id, update: update, token: token) }
    func transferMoney(_ operation: TransferMoneyOperation) async throws { try await credentials.prepare(); _ = try await client.createTransfer(budgetID: budget.id, transfer: operation.apiValue, token: token) }
    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws { try await credentials.prepare(); _ = try await client.updateTransfer(budgetID: budget.id, transferID: id, transfer: operation.apiValue, token: token) }
    func deleteTransfer(id: String) async throws { try await credentials.prepare(); try await client.deleteTransfer(budgetID: budget.id, transferID: id, token: token) }
    func reconcileAccount(_ operation: ReconcileAccountOperation) async throws { try await credentials.prepare(); _ = try await client.reconcileAccount(budgetID: budget.id, accountID: operation.accountID, request: APIReconcileRequest(statementBalanceMinor: operation.statementBalanceMinor, throughDate: operation.throughDate, createAdjustment: operation.createAdjustment, adjustmentReason: operation.reason, expectedClearedBalanceMinor: operation.expectedClearedBalanceMinor), token: token) }
    func assignMoney(_ operation: AssignMoneyOperation) async throws { try await credentials.prepare(); _ = try await client.updateAssignment(budgetID: budget.id, categoryID: operation.categoryID, month: operation.month, assignedMinor: operation.assignedMinor, expectedAllocationVersion: operation.expectedVersion, token: token) }
    func moveMoney(_ operation: MoveMoneyOperation) async throws { try await credentials.prepare(); _ = try await client.transferAllocation(budgetID: budget.id, transfer: APIAllocationTransferCreate(sourceCategoryID: operation.sourceCategoryID, destinationCategoryID: operation.destinationCategoryID, amountMinor: operation.amountMinor, occurredOn: operation.occurredOn, note: operation.note, expectedAllocationVersion: operation.expectedVersion), token: token) }
    func createCategory(groupID: String, groupName: String, newGroupName: String, name: String, delegatedUserID: String?) async throws { try await credentials.prepare(); var targetGroupID = groupID; if !newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { targetGroupID = try await client.createCategoryGroup(budgetID: budget.id, group: APICategoryGroupCreate(name: newGroupName), token: token).id }; _ = try await client.createCategory(budgetID: budget.id, category: APICategoryCreate(groupID: targetGroupID, name: name, delegatedUserID: delegatedUserID), token: token) }
    func createGroup(name: String) async throws { try await credentials.prepare(); _ = try await client.createCategoryGroup(budgetID: budget.id, group: APICategoryGroupCreate(name: name), token: token) }
    func createAccount(_ operation: CreateAccountOperation) async throws { try await credentials.prepare(); _ = try await client.createAccount(budgetID: budget.id, account: APIAccountCreate(name: operation.name, accountType: operation.kind, isOnBudget: operation.isOnBudget, startingBalanceMinor: operation.openingBalanceMinor), token: token) }
    func updateAccount(_ operation: UpdateAccountMetadataOperation) async throws { try await credentials.prepare(); _ = try await client.updateAccount(budgetID: budget.id, accountID: operation.accountID, account: APIAccountUpdate(name: operation.name, accountType: operation.kind), token: token) }
    func createRequest(_ value: APIFinancialRequestCreate) async throws { try await credentials.prepare(); _ = try await client.createFinancialRequest(budgetID: budget.id, request: value, token: token) }
    func updateCategory(id: String, value: APICategoryUpdate, groupName: String?, existingDelegatedUserID: String?, delegatedUserID: String?) async throws { try await credentials.prepare(); _ = try await client.updateCategory(budgetID: budget.id, categoryID: id, category: value, token: token); if existingDelegatedUserID != delegatedUserID { _ = try await client.updateCategoryDelegation(budgetID: budget.id, categoryID: id, delegatedUserID: delegatedUserID, token: token) } }
    func updateGroup(id: String, currentName: String?, value: APICategoryGroupUpdate) async throws { try await credentials.prepare(); _ = try await client.updateCategoryGroup(budgetID: budget.id, groupID: id, group: value, token: token) }
    func deleteGroup(id: String, currentName: String?) async throws { try await credentials.prepare(); try await client.deleteCategoryGroup(budgetID: budget.id, groupID: id, token: token) }
    func deleteCategory(id: String) async throws { try await credentials.prepare(); try await client.deleteCategory(budgetID: budget.id, categoryID: id, token: token) }
    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws { try await credentials.prepare(); _ = try await client.upsertCategoryTarget(budgetID: budget.id, categoryID: categoryID, target: value, token: token) }
    func deleteTarget(categoryID: String) async throws { try await credentials.prepare(); try await client.deleteCategoryTarget(budgetID: budget.id, categoryID: categoryID, token: token) }
    func createSchedule(_ operation: ScheduleOperation) async throws { try await credentials.prepare(); _ = try await client.createScheduledTransaction(budgetID: budget.id, schedule: operation.apiValue, token: token) }
    func updateSchedule(id: String, operation: ScheduleOperation) async throws { try await credentials.prepare(); _ = try await client.updateScheduledTransaction(budgetID: budget.id, scheduleID: id, schedule: operation.apiValue, token: token) }
    func deleteSchedule(id: String) async throws { try await credentials.prepare(); try await client.deleteScheduledTransaction(budgetID: budget.id, scheduleID: id, token: token) }
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation {
        try await credentials.prepare()
        let value = try await client.realizeScheduledTransaction(budgetID: budget.id, scheduleID: id, token: token)
        return ScheduledRealizationObservation(scheduleID: value.scheduledTransactionID, transactionIDs: value.transactionIDs, realizedOn: value.realizedOn, nextDate: value.nextDate, isActive: value.isActive, lastRealizedOn: value.lastRealizedOn)
    }
    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws { try await credentials.prepare(); _ = try await client.decideFinancialRequest(budgetID: budget.id, requestID: id, decision: APIFinancialRequestDecision(decision: decision, expectedRequestVersion: version, approvedAmountMinor: amount, sourceCategoryID: sourceCategoryID, note: note), token: token) }
    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview { try await credentials.prepare(); return try await client.smartFundingPreview(budgetID: budget.id, month: month, token: token) }
    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws { try await credentials.prepare(); _ = try await client.commitSmartFunding(budgetID: budget.id, month: preview.month, expectedAllocationVersion: preview.allocationVersion, token: token) }
    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws { try await credentials.prepare(); _ = try await client.updateDelegatedBudget(budgetID: budget.id, userID: userID, policy: value, token: token) }
}

@MainActor
private final class LiveWorkspaceDataSource: WorkspaceDataSource {
    let budget: APIBudget
    private let credentials: LiveWorkspaceCredentials
    var serverURL: URL { credentials.serverURL }
    var token: String { credentials.token }
    let commands: LiveWorkspaceCommandRepository
    init(budget: APIBudget, serverURL: URL, token: String, clientFactory: @escaping (URL) throws -> APIClient = { try APIClient(baseURL: $0) }) {
        self.budget = budget
        let credentials = LiveWorkspaceCredentials(serverURL: serverURL, token: token, clientFactory: clientFactory)
        self.credentials = credentials
        commands = LiveWorkspaceCommandRepository(budget: budget, credentials: credentials)
    }

    func updateCredentials(serverURL: URL, token: String) { credentials.update(serverURL: serverURL, token: token) }
    func bindCredentialAuthority(_ resolver: @escaping LiveWorkspaceCredentials.Resolver) { credentials.bind(resolver) }

    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot {
        try await credentials.prepare()
        let client = try credentials.client()
        let month = BudgetWorkspaceStore.dateString(planMonth).prefix(7) + "-01"
        let start = BudgetWorkspaceStore.dateString(report.start), end = BudgetWorkspaceStore.dateString(report.end)
        async let loadedAccounts = client.accounts(budgetID: budget.id, token: token)
        async let loadedTransactions = client.transactions(budgetID: budget.id, token: token)
        async let loadedCategories = client.categories(budgetID: budget.id, token: token)
        async let loadedGroups = client.categoryGroups(budgetID: budget.id, token: token)
        async let loadedSummary = client.monthSummary(budgetID: budget.id, month: String(month), token: token)
        async let loadedSpending = client.spendingReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], categoryIDs: report.categoryID.isEmpty ? [] : [report.categoryID], categoryGroups: report.categoryGroup.isEmpty ? [] : [report.categoryGroup], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], transactionType: report.transactionType.isEmpty ? nil : report.transactionType, cleared: report.cleared == "all" ? nil : report.cleared == "cleared", includeTracking: report.includeTracking, token: token)
        async let loadedIncome = client.incomeSpendingReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], cleared: report.cleared == "all" ? nil : report.cleared == "cleared", includeTracking: report.includeTracking, token: token)
        let (accounts, transactions, categories, groups, summary, spending, income) = try await (loadedAccounts, loadedTransactions, loadedCategories, loadedGroups, loadedSummary, loadedSpending, loadedIncome)
        let allocationOperations = budget.can("view_allocation_history") ? (try? await client.allocationOperations(budgetID: budget.id, token: token)) ?? [] : []
        let schedules = budget.can("view_transactions") ? try await client.scheduledTransactions(budgetID: budget.id, includeInactive: true, token: token) : []
        let targets = await withTaskGroup(of: APICategoryTarget?.self) { group in for category in categories { group.addTask { try? await client.categoryTarget(budgetID: self.budget.id, categoryID: category.id, token: self.token) } }; var values: [APICategoryTarget] = []; for await target in group { if let target { values.append(target) } }; return values }
        let balances = await withTaskGroup(of: APIAccountBalance?.self) { group in for account in accounts { group.addTask { try? await client.accountBalance(budgetID: self.budget.id, accountID: account.id, token: self.token) } }; var values: [APIAccountBalance] = []; for await value in group { if let value { values.append(value) } }; return values }
        let requests = (budget.can("request_money") || budget.can("approve_request")) ? (try? await client.financialRequests(budgetID: budget.id, token: token)) ?? [] : []
        let allowances = (try? await client.allowancePlans(budgetID: budget.id, token: token)) ?? []
        let delegated = try? await client.delegatedBudget(budgetID: budget.id, token: token)
        let forecast: APIForecast? = if budget.can("view_account_balances") { try? await client.forecast(budgetID: budget.id, through: BudgetWorkspaceStore.dateString(Calendar.current.date(byAdding: .day, value: 90, to: Date())!), token: token) } else { nil }
        let members = budget.can("manage_allowances") ? (try? await client.householdMembers(householdID: budget.householdID, token: token)) ?? [] : []
        let delegatedBudgets = budget.can("manage_allowances") ? (try? await client.delegatedBudgets(budgetID: budget.id, token: token)) ?? [] : []
        return WorkspaceSnapshot(accounts: accounts, accountBalances: Dictionary(uniqueKeysWithValues: balances.map { ($0.accountID, $0) }), categories: categories, groups: groups, transactions: transactions, summary: summary, payees: [], requests: requests, allowances: allowances, spending: spending, income: income, delegated: delegated, forecast: forecast, members: members, delegatedBudgets: delegatedBudgets, allocationOperations: allocationOperations, targets: targets, schedules: schedules)
    }
}

@MainActor
final class BudgetWorkspaceStore: ObservableObject {
    let budget: APIBudget
    @Published var summary: APIMonthSummary?
    @Published var accounts: [APIAccount] = []
    @Published var accountBalances: [String: APIAccountBalance] = [:]
    @Published var payees: [APIPayee] = []
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
    @Published private(set) var liveCredentialRevision = 0
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
    private var dataSource: WorkspaceDataSource?
    private var commandRepository: WorkspaceCommandRepository?
    private var applicationServices: BudgetApplicationServices?
    private var transactionBrowseTask: Task<APITransactionPage, Error>?
    private var transactionBrowseQuery: APITransactionQuery?
    private var transactionBrowseOperationID: UUID?

    init(budget: APIBudget) { self.budget = budget; dataSource = nil; commandRepository = nil; applicationServices = nil }
    private init(dataSource: DemoWorkspaceDataSource) { self.budget = dataSource.budget; self.dataSource = dataSource; commandRepository = dataSource; applicationServices = BudgetApplicationServices(repository: dataSource) }
    static func demo(fresh: Bool = false) -> BudgetWorkspaceStore { BudgetWorkspaceStore(dataSource: DemoWorkspaceDataSource(fresh: fresh)) }
    static func production(context: WorkspaceRouteContext, clientFactory: @escaping (URL) throws -> APIClient = { try APIClient(baseURL: $0) }) -> BudgetWorkspaceStore {
        guard case let .live(budget, serverURL, token) = context else { return .demo() }
        let source = LiveWorkspaceDataSource(budget: budget, serverURL: serverURL, token: token, clientFactory: clientFactory)
        let store = BudgetWorkspaceStore(budget: source.budget)
        store.dataSource = source; store.commandRepository = source.commands; store.applicationServices = BudgetApplicationServices(repository: source.commands)
        return store
    }

    func load(serverURL: URL, token: String) async {
        if dataSource == nil {
            let source = LiveWorkspaceDataSource(budget: budget, serverURL: serverURL, token: token)
            dataSource = source; commandRepository = source.commands; applicationServices = BudgetApplicationServices(repository: source.commands)
        }
        await loadSnapshot()
    }

    func updateLiveCredentials(serverURL: URL, token: String) {
        guard let current = dataSource as? LiveWorkspaceDataSource,
              current.serverURL != serverURL || current.token != token else { return }
        current.updateCredentials(serverURL: serverURL, token: token)
        liveCredentialRevision += 1
    }


    func bindLiveCredentialAuthority(_ resolver: @escaping LiveWorkspaceCredentials.Resolver) {
        guard let current = dataSource as? LiveWorkspaceDataSource else { return }
        current.bindCredentialAuthority(resolver)
    }

    func usesLiveCredential(_ token: String) -> Bool {
        (dataSource as? LiveWorkspaceDataSource)?.token == token
    }

    private func loadSnapshot() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let dataSource {
                let range = reportRange()
                let query = WorkspaceReportQuery(start: range.0, end: range.1, accountID: reportAccountID, categoryID: reportCategoryID, categoryGroup: reportCategoryGroup, payee: reportPayee, memberID: reportMemberID, transactionType: reportTransactionType, cleared: reportCleared, includeTracking: includeTrackingAccounts)
                let value = try await dataSource.snapshot(planMonth: planMonth, report: query)
                accounts = value.accounts; accountBalances = value.accountBalances; categories = value.categories; groups = value.groups; transactions = value.transactions; payees = value.payees
                summary = value.summary; requests = value.requests; allowances = value.allowances; spendingReport = value.spending
                incomeReport = value.income; delegatedBudget = value.delegated; forecast = value.forecast
                householdMembers = value.members; delegatedBudgets = value.delegatedBudgets; allocationOperations = value.allocationOperations; errorMessage = nil
                targets = Dictionary(uniqueKeysWithValues: value.targets.map { ($0.categoryID, $0) })
                scheduledTransactions = value.schedules
                return
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async { await loadSnapshot() }

    func createTransaction(_ operation: RecordTransactionOperation) async throws {
        try await services().transactions.record(operation)
        await refresh()
    }

    func updateTransaction(id: String, operation: RecordTransactionOperation) async throws {
        try await services().transactions.update(id: id, operation: operation)
        await refresh()
    }

    func canQuickSetCleared(_ transaction: APITransaction) -> Bool {
        budget.can("edit_transaction")
            && (transaction.status ?? "posted") == "posted"
            && !transaction.isReconciled
            && transaction.transferID == nil
            && transaction.scheduledTransactionID == nil
            && !["Starting Balance", "Reconciliation adjustment"].contains(transaction.payeeName)
    }

    func setTransactionCleared(id: String, cleared: Bool) async throws {
        guard let transaction = transactions.first(where: { $0.id == id }) else { throw workspaceRepositoryError("Transaction not found.") }
        guard canQuickSetCleared(transaction) else { throw workspaceRepositoryError("This transaction cannot be changed through quick clearing.") }
        try await bulkUpdateTransactions(.init(transactionIDs: [id], action: "set_cleared", cleared: cleared))
    }

    func createPayee(_ operation: CreatePayeeOperation) async throws { try await services().payees.create(operation); await refresh() }
    func searchPayees(query: String = "", includeArchived: Bool = false, limit: Int = 20, cursor: String? = nil) async throws -> APIPayeePage { try await services().payees.search(query: query, includeArchived: includeArchived, limit: limit, cursor: cursor) }
    func updatePayee(_ operation: UpdatePayeeOperation) async throws { try await services().payees.update(operation); await refresh() }
    func mergePayee(sourceID: String, destinationID: String) async throws { try await services().payees.merge(sourceID: sourceID, destinationID: destinationID); await refresh() }
    func createPayeeAlias(payeeID: String, displayName: String) async throws { try await services().payees.createAlias(payeeID: payeeID, displayName: displayName); await refresh() }
    func deletePayeeAlias(payeeID: String, aliasID: String) async throws { try await services().payees.deleteAlias(payeeID: payeeID, aliasID: aliasID); await refresh() }

    func deleteTransaction(id: String) async throws {
        try await services().transactions.delete(id: id)
        await refresh()
    }

    func duplicateTransaction(id: String, occurredOn: String) async throws {
        try await services().transactions.duplicate(id: id, occurredOn: occurredOn)
        await refresh()
    }

    func voidTransaction(id: String, reason: String) async throws {
        try await services().transactions.void(id: id, reason: reason)
        await refresh()
    }

    func createScheduleFromTransaction(id: String, operation: MakeRecurringOperation) async throws {
        try await services().transactions.makeRecurring(id: id, operation: operation)
        await refresh()
    }

    func transactionAttachments(id: String) async throws -> [APITransactionAttachment] { try await services().transactions.attachments(id: id) }
    func uploadTransactionAttachment(id: String, filename: String, contentType: String, data: Data) async throws { try await services().transactions.uploadAttachment(id: id, filename: filename, contentType: contentType, data: data); await refresh() }
    func downloadTransactionAttachment(transactionID: String, attachmentID: String) async throws -> Data { try await services().transactions.downloadAttachment(transactionID: transactionID, attachmentID: attachmentID) }
    func detachTransactionAttachment(transactionID: String, attachmentID: String) async throws { try await services().transactions.detachAttachment(transactionID: transactionID, attachmentID: attachmentID); await refresh() }

    func bulkUpdateTransactions(_ update: APITransactionBulkUpdate) async throws {
        try await services().transactions.bulkUpdate(update)
        await refresh()
    }

    func browseTransactions(_ query: APITransactionQuery) async throws -> APITransactionPage {
        if transactionBrowseQuery == query, let transactionBrowseTask {
            return try await transactionBrowseTask.value
        }
        let service = try services().transactions
        let operationID = UUID()
        let task = Task { try await service.browse(query) }
        transactionBrowseQuery = query
        transactionBrowseTask = task
        transactionBrowseOperationID = operationID
        defer {
            if transactionBrowseOperationID == operationID {
                transactionBrowseTask = nil
                transactionBrowseQuery = nil
                transactionBrowseOperationID = nil
            }
        }
        return try await task.value
    }

    func createTransfer(_ operation: TransferMoneyOperation) async throws {
        try await services().transactions.transfer(operation)
        await refresh()
    }

    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws {
        try await services().transactions.updateTransfer(id: id, operation: operation)
        await refresh()
    }

    func deleteTransfer(id: String) async throws {
        try await services().transactions.deleteTransfer(id: id)
        await refresh()
    }

    func reconcile(accountID: String, statementBalance: Int64, throughDate: String, createAdjustment: Bool, reason: String) async throws {
        let cleared = transactions.filter { $0.accountID == accountID && $0.isCleared }.reduce(0) { $0 + $1.amountMinor }
        try await services().accounts.reconcile(ReconcileAccountOperation(accountID: accountID, statementBalanceMinor: statementBalance, throughDate: throughDate, createAdjustment: createAdjustment, reason: reason, expectedClearedBalanceMinor: cleared))
        await refresh()
    }

    func updateAssignment(categoryID: String, month: String, assignedMinor: Int64, expectedVersion: Int) async throws {
        try await services().planning.assign(AssignMoneyOperation(categoryID: categoryID, month: month, assignedMinor: assignedMinor, expectedVersion: expectedVersion))
        await refresh()
    }

    func moveAllocation(_ operation: MoveMoneyOperation) async throws {
        try await services().planning.move(operation)
        await refresh()
    }

    func createCategory(groupID: String, newGroupName: String, name: String, delegatedUserID: String?) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw workspaceRepositoryError("Enter a category name.") }
        if !groupID.isEmpty && categories.contains(where: { $0.groupID == groupID && normalizedCategoryName($0.name) == normalizedCategoryName(trimmedName) }) {
            throw workspaceRepositoryError("A category with this name already exists in the group.")
        }
        try await commands().createCategory(groupID: groupID, groupName: groups.first(where: { $0.id == groupID })?.name ?? "", newGroupName: newGroupName, name: trimmedName, delegatedUserID: delegatedUserID)
        await refresh()
    }

    func createGroup(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw workspaceRepositoryError("Enter a category group name.") }
        try await commands().createGroup(name: trimmed)
        await refresh()
    }

    func createAccount(_ operation: CreateAccountOperation) async throws {
        try await services().accounts.create(operation)
        await refresh()
    }

    func updateAccount(_ operation: UpdateAccountMetadataOperation) async throws {
        try await services().accounts.update(operation)
        await refresh()
    }

    func createRequest(_ value: APIFinancialRequestCreate) async throws {
        try await commands().createRequest(value)
        await refresh()
    }

    func updateCategory(id: String, value: APICategoryUpdate, delegatedUserID: String?) async throws {
        let existing = categories.first(where: { $0.id == id })
        if categories.contains(where: { $0.id != id && $0.groupID == value.groupID && normalizedCategoryName($0.name) == normalizedCategoryName(value.name) }) {
            throw workspaceRepositoryError("A category with this name already exists in the group.")
        }
        try await commands().updateCategory(id: id, value: value, groupName: groups.first(where: { $0.id == value.groupID })?.name, existingDelegatedUserID: existing?.delegatedUserID, delegatedUserID: delegatedUserID)
        await refresh()
    }
    func updateGroup(id: String, value: APICategoryGroupUpdate) async throws {
        try await commands().updateGroup(id: id, currentName: groups.first(where: { $0.id == id })?.name, value: value)
        await refresh()
    }
    func deleteGroup(id: String) async throws {
        try await commands().deleteGroup(id: id, currentName: groups.first(where: { $0.id == id })?.name)
        await refresh()
    }
    func deleteCategory(id: String) async throws {
        try await commands().deleteCategory(id: id)
        await refresh()
    }

    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws {
        try await commands().saveTarget(categoryID: categoryID, value: value)
        await refresh()
    }
    func deleteTarget(categoryID: String) async throws {
        try await commands().deleteTarget(categoryID: categoryID)
        await refresh()
    }

    func createSchedule(_ operation: ScheduleOperation) async throws {
        try await services().schedules.create(operation)
        await refresh()
    }

    func updateSchedule(id: String, operation: ScheduleOperation) async throws {
        try await services().schedules.update(id: id, operation: operation)
        await refresh()
    }

    func deleteSchedule(id: String) async throws {
        try await services().schedules.delete(id: id)
        await refresh()
    }

    @discardableResult func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation {
        let result = try await services().schedules.realize(id: id)
        await refresh()
        return result
    }

    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws {
        try await commands().decideRequest(id: id, decision: decision, version: version, amount: amount, sourceCategoryID: sourceCategoryID, note: note)
        await refresh()
    }

    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview {
        try await commands().smartFundingPreview(month: month)
    }

    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws {
        try await commands().commitSmartFunding(preview)
        await refresh()
    }

    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws {
        try await commands().updateDelegatedPolicy(userID: userID, value: value)
        await refresh()
    }

    private func commands() throws -> WorkspaceCommandRepository {
        guard let commandRepository else { throw workspaceRepositoryError("Workspace repository is not configured.") }
        return commandRepository
    }

    private func services() throws -> BudgetApplicationServices {
        guard let applicationServices else { throw BudgetApplicationError.temporarilyUnavailable("Workspace services are not configured.") }
        return applicationServices
    }

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
            if $0.occurredOn == $1.occurredOn {
                if $0.createdAt != $1.createdAt { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
                if $0.payeeName != $1.payeeName { return $0.payeeName.localizedStandardCompare($1.payeeName) == .orderedAscending }
                if $0.amountMinor != $1.amountMinor { return $0.amountMinor > $1.amountMinor }
                return $0.memo.localizedStandardCompare($1.memo) == .orderedAscending
            }
            return $0.occurredOn > $1.occurredOn
        }
    }

    static func compactDate(_ value: String, now: Date = Date()) -> String {
        let date = parseDate(value)
        let includeYear = Calendar.current.component(.year, from: date) != Calendar.current.component(.year, from: now)
        return includeYear ? date.formatted(.dateTime.month(.abbreviated).day().year()) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    func reportRange(calendar: Calendar = .current, now: Date = Date()) -> (Date, Date) {
        let effectiveNow = dataSource is DemoWorkspaceDataSource ? Date.demo(monthsAgo: 0, day: 30) : now
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
    private let selectionOverride: Binding<Int>?

    init(budget: APIBudget) { _store = StateObject(wrappedValue: BudgetWorkspaceStore(budget: budget)); _selectedTab = State(initialValue: 0); selectionOverride = nil }
    init(store: BudgetWorkspaceStore) { _store = StateObject(wrappedValue: store); _selectedTab = State(initialValue: Self.launchTab); selectionOverride = nil }
    private init(demo: Bool) { _store = StateObject(wrappedValue: .demo()); _selectedTab = State(initialValue: Self.launchTab); selectionOverride = nil }
    init(testStore: BudgetWorkspaceStore, selection: Binding<Int>) { _store = StateObject(wrappedValue: testStore); _selectedTab = State(initialValue: 0); selectionOverride = selection }
    static func demo() -> BudgetWorkspaceView { BudgetWorkspaceView(demo: true) }
    private var tabSelection: Binding<Int> { selectionOverride ?? $selectedTab }
    private var activeTab: Int { selectionOverride?.wrappedValue ?? selectedTab }
    private static var launchTab: Int {
        let screen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-screen=") }?.split(separator: "=").last.map(String.init) ?? "home"
        return ["home":0,"plan":1,"activity":2,"transaction":2,"accounts":3,"credit":3,"insights":4][screen] ?? 0
    }

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack { LiveHomeView().workspaceProfileToolbar { showingSettings = true } }.tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack { LivePlanView().workspaceProfileToolbar { showingSettings = true } }.tabItem { Label("Plan", systemImage: "square.grid.2x2.fill") }.tag(1)
            NavigationStack { LiveActivityView().workspaceProfileToolbar { showingSettings = true } }.tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { LiveAccountsView().workspaceProfileToolbar { showingSettings = true } }.tabItem { Label("Accounts", systemImage: "creditcard.fill") }.tag(3)
            NavigationStack { LiveInsightsView().workspaceProfileToolbar { showingSettings = true } }.tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }.tag(4)
        }
        // iOS 27 can change selection without materializing a previously lazy NavigationStack.
        // This is intentional identity replacement at the shell boundary; active editor drafts are
        // modal and remain locally owned, while the selected production tab is guaranteed to render.
        .id(activeTab)
        .tint(Theme.accent)
        .overlay { if store.isLoading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task(id: session.token) { [session] in
            store.bindLiveCredentialAuthority { forceRefresh in
                return try await session.currentLiveCredentials(forceRefresh: forceRefresh, caller: "workspace.request")
            }
            if let token = session.token, let serverURL = session.serverURL {
                store.updateLiveCredentials(serverURL: serverURL, token: token)
            }
            await reload()
        }
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
        // The composition root has already selected a repository. Feature UI never branches on the
        // application source and cannot start authentication or credential refresh work.
        await store.refresh()
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

private struct WorkspaceProfileToolbar: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: action) { Image(systemName: "person.crop.circle") }
                    .accessibilityIdentifier("profile-settings-button")
            }
        }
    }
}

private extension View {
    func workspaceProfileToolbar(action: @escaping () -> Void) -> some View {
        modifier(WorkspaceProfileToolbar(action: action))
    }
}

private struct LiveHomeView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
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
        }.navigationTitle(store.budget.name)
    }
}

private struct LiveForecastView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { if let forecast = store.forecast { Section { Text("Projected values include schedules but are not spendable until entered.").font(.footnote).foregroundStyle(.secondary) }; Section("Household cash") { LabeledContent("Today", value: store.format(forecast.actualTotalOnBudgetMinor)); LabeledContent("At \(forecast.through)", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest", value: store.format(forecast.lowestProjectedTotalMinor)) }; Section("Accounts") { ForEach(forecast.accounts) { account in VStack(alignment: .leading) { Text(account.name); HStack { Text("Now \(store.format(account.actualBalanceMinor))"); Spacer(); Text("Projected \(store.format(account.projectedBalanceMinor))") }.font(.caption).foregroundStyle(.secondary) } } }; Section("Scheduled activity") { if forecast.occurrences.isEmpty { Text("No scheduled transactions in this period").foregroundStyle(.secondary) }; ForEach(forecast.occurrences) { item in if let schedule = store.scheduledTransactions.first(where: { $0.id == item.scheduledTransactionID }) { NavigationLink { LiveScheduledTransactionEditor(schedule: schedule, currencyCode: store.budget.currencyCode) } label: { ScheduledActivityPresentation(name: item.name, amountMinor: item.amountMinor, occurrenceDate: item.occurredOn, context: item.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }) } } else { ScheduledActivityPresentation(name: item.name, amountMinor: item.amountMinor, occurrenceDate: item.occurredOn, context: nil) } } } } }.navigationTitle("Forecast") }
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

private struct MoveMoneyPresentation: Identifiable {
    let id = UUID()
    let sourceCategoryID: String?
}

private struct LivePlanView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var editing: APICategoryMonth?
    @State private var movePresentation: MoveMoneyPresentation?
    @State private var categoryCreation: CategoryCreationPresentation?
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
                                else { categoryCreation = .global }
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
                let groupCategories = store.categories.filter { $0.groupID == group.id && !$0.isArchived }
                let groupRows = rows.filter { row in store.categories.first(where: { $0.id == row.categoryID })?.groupID == group.id }
                if groupCategories.isEmpty {
                    Section(group.name) {
                        Text("No categories yet").foregroundStyle(.secondary)
                        if store.budget.can("manage_budget_structure") || store.budget.can("manage_own_categories") {
                            Button("Add Category", systemImage: "folder.badge.plus") { categoryCreation = .contextual(groupID: group.id) }
                                .accessibilityIdentifier("empty-group-add-category-\(group.id)")
                        }
                    }
                } else if !groupRows.isEmpty {
                    Section(group.name) {
                        ForEach(groupRows) { category in
                            NavigationLink {
                                LivePlanCategoryDetailView(categoryID: category.categoryID, assign: { editing = category }, move: { movePresentation = .init(sourceCategoryID: category.categoryID) }, manage: { managing = store.categories.first(where: { $0.id == category.categoryID }) })
                            } label: { PlanCategoryRow(category: category) }
                                .accessibilityIdentifier("plan-category-\(category.categoryID)")
                                .contextMenu { if let model = store.categories.first(where: { $0.id == category.categoryID }), canManage(model) { Button("Manage Category", systemImage: "pencil") { managing = model } } }
                        }
                        if store.budget.can("manage_budget_structure") || store.budget.can("manage_own_categories") {
                            Button("Add Category", systemImage: "folder.badge.plus") { categoryCreation = .contextual(groupID: group.id) }
                                .accessibilityIdentifier("group-add-category-\(group.id)")
                        }
                    }
                }
            }
        }.accessibilityIdentifier("plan-screen").navigationTitle("Plan").toolbar {
            Menu {
                if store.delegatedBudget == nil && store.budget.can("assign_money") { Button("Smart Funding", systemImage: "sparkles") { showSmartFunding = true } }
                if store.budget.can("manage_budget_structure") || store.budget.can("manage_own_categories") { Button("Add category", systemImage: "folder.badge.plus") { categoryCreation = .global }.accessibilityIdentifier("global-add-category-action") }
                if store.budget.can("manage_budget_structure") { Button("Add category group", systemImage: "folder.badge.plus") { showGroupCreation = true }.accessibilityIdentifier("add-category-group-action") }
                if store.budget.can("manage_budget_structure") { Button("Manage groups", systemImage: "folder") { showGroups = true }.accessibilityIdentifier("manage-category-groups-action") }
                if store.budget.can("move_money") { Button("Move money", systemImage: "arrow.left.arrow.right") { movePresentation = .init(sourceCategoryID: nil) } }
                if store.budget.can("request_money") { Button("Request money", systemImage: "hand.raised") { showRequest = true } }
            } label: { Image(systemName: "plus") }.accessibilityIdentifier("plan-add-menu")
        }
        .sheet(item: $editing) { category in editAssignment(category) }
        .sheet(item: $movePresentation) { presentation in moveMoney(initialSourceCategoryID: presentation.sourceCategoryID) }
        .sheet(item: $categoryCreation) { presentation in createCategory(presentation) }
        .sheet(isPresented: $showSmartFunding) { smartFunding }
        .sheet(isPresented: $showRequest) { FundingRequestView(budget: store.budget, categories: store.categories, onSaved: reload) }
        .sheet(item: $managing) { category in LiveCategoryEditView(budget: store.budget, category: category, groups: store.groups, members: store.householdMembers, onSaved: reload) }
        .sheet(isPresented: $showGroups) { LiveGroupManagementView() }
        .sheet(isPresented: $showGroupCreation) { GroupCreationView() }
    }
    private var activationExplanation: String {
        if store.groups.isEmpty { return "Category groups organize the purposes in your plan. Create one first, then add a category for something you spend or save for." }
        return "Categories give money a specific purpose. After you add one, open it and choose Assign money to move Available to Assign into that category."
    }
    @ViewBuilder private func editAssignment(_ category: APICategoryMonth) -> some View {
        if let summary = store.summary {
            AssignmentEditView(budget: store.budget, category: category, month: String(BudgetWorkspaceStore.dateString(store.planMonth).prefix(7)) + "-01", expectedAllocationVersion: summary.allocationVersion, onSaved: reload)
        }
    }
    @ViewBuilder private func moveMoney(initialSourceCategoryID: String?) -> some View {
        if let summary = store.summary {
            AllocationTransferView(budget: store.budget, categories: summary.categories, expectedAllocationVersion: summary.allocationVersion, initialSourceCategoryID: initialSourceCategoryID, onSaved: reload)
        }
    }
    @ViewBuilder private func createCategory(_ presentation: CategoryCreationPresentation) -> some View {
        CategoryCreationView(
                budget: store.budget,
                groups: store.groups,
                onSaved: reload,
                initialGroupID: presentation.groupID ?? "",
                delegatedUserID: store.budget.can("manage_own_categories") && !store.budget.can("manage_budget_structure") ? session.profile?.id : nil
            )
    }
    @ViewBuilder private var smartFunding: some View {
        LiveSmartFundingView(budget: store.budget, month: String(BudgetWorkspaceStore.dateString(store.planMonth).prefix(7)) + "-01", onSaved: reload)
    }
    private func reload() async { await store.refresh() }
    private func canManage(_ category: APICategory) -> Bool { store.budget.can("manage_budget_structure") || (store.budget.can("manage_own_categories") && category.delegatedUserID == session.profile?.id) }
    private func changeMonth(_ value: Int) { if let next = Calendar.current.date(byAdding: .month, value: value, to: store.planMonth) { store.planMonth = next; Task { await reload() } } }
}

private struct CategoryCreationPresentation: Identifiable {
    let id = UUID()
    let groupID: String?

    static var global: Self { .init(groupID: nil) }
    static func contextual(groupID: String) -> Self { .init(groupID: groupID) }
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
                TextField("Group name", text: $name).accessibilityIdentifier("new-group-name")
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
    @State private var showGroupCreation = false
    var body: some View { NavigationStack { List { ForEach(store.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in Button { editing=group } label: { HStack { VStack(alignment:.leading){Text(group.name);Text(group.isArchived ? "Hidden" : "Visible").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary) } } } }.navigationTitle("Category Groups").toolbar { ToolbarItem(placement:.cancellationAction){Button("Add Group",systemImage:"plus"){showGroupCreation=true}.accessibilityIdentifier("manage-groups-add-action")};ToolbarItem(placement:.confirmationAction){Button("Done"){dismiss()}} }.sheet(item:$editing){LiveGroupEditor(group:$0)}.sheet(isPresented:$showGroupCreation){GroupCreationView()} } }
}

private struct LiveGroupEditor: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore; @Environment(\.dismiss) private var dismiss
    let group: APICategoryGroup
    @State private var name: String; @State private var archived: Bool; @State private var saving=false; @State private var error:String?; @State private var confirmDelete=false
    init(group: APICategoryGroup){self.group=group;_name=State(initialValue:group.name);_archived=State(initialValue:group.isArchived)}
    var body: some View { NavigationStack { Form { TextField("Name",text:$name);Toggle("Hidden",isOn:$archived);Section{Text("Hiding a group preserves every category and its financial history.").font(.footnote).foregroundStyle(.secondary)};Section{Button("Delete Empty Group",role:.destructive){confirmDelete=true}} }.navigationTitle("Manage Group").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || saving)}}.confirmationDialog("Delete this group?",isPresented:$confirmDelete){Button("Delete Empty Group",role:.destructive){Task{await remove()}}} .alert("Unable to update group",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("OK",role:.cancel){}}message:{Text(error ?? "Unknown error")} } }
    private func save()async{saving=true;defer{saving=false};do{try await store.updateGroup(id:group.id,value:APICategoryGroupUpdate(name:name,sortOrder:group.sortOrder,isArchived:archived));dismiss()}catch{self.error=error.localizedDescription}}
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
    var body: some View { NavigationStack { Form { Section(categoryName) { Picker("Target type",selection:$type){Text("Monthly funding").tag("monthly_funding");Text("Savings balance").tag("savings_balance");Text("By date").tag("target_by_date");Text("Recurring expense").tag("recurring_expense")};CurrencyAmountField("Target amount",text:$amount,currencyCode:store.budget.currencyCode);CurrencyAmountField("Minimum contribution",text:$minimum,currencyCode:store.budget.currencyCode,allowsZero:true);if dated{DatePicker("Due date",selection:$dueDate,displayedComponents:.date)};if type=="recurring_expense"{Stepper("Every \(recurrence) month\(recurrence == 1 ? "" : "s")",value:$recurrence,in:1...1200);Button("Set annual cadence"){recurrence=12}};Stepper("Priority \(priority)",value:$priority,in:0...100);Toggle("Target active",isOn:$active)};Section{Text("Targets guide planning only. Saving this target does not move money, change account balances, or increase Unassigned.").font(.footnote).foregroundStyle(.secondary)};if existing != nil{Section{Button("Delete Target",role:.destructive){confirmDelete=true}}} }.navigationTitle(existing == nil ? "New Target" : "Edit Target").navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(parsed==nil || parsedMinimum==nil || saving)}}.confirmationDialog("Delete this target?",isPresented:$confirmDelete){Button("Delete Target",role:.destructive){Task{await remove()}}}.alert("Unable to save target",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("OK",role:.cancel){}}message:{Text(error ?? "Unknown error")} } }
    private func save() async { guard let parsed,let parsedMinimum else{return};saving=true;defer{saving=false};do{try await store.saveTarget(categoryID:categoryID,value:APICategoryTargetUpsert(targetType:type,targetAmountMinor:parsed,targetDate:dated ? BudgetWorkspaceStore.dateString(dueDate):nil,recurrenceMonths:type == "recurring_expense" ? recurrence:nil,minimumContributionMinor:parsedMinimum,priority:priority,isActive:active));dismiss()}catch{self.error=error.localizedDescription} }
    private func remove() async { saving=true;defer{saving=false};do{try await store.deleteTarget(categoryID:categoryID);dismiss()}catch{self.error=error.localizedDescription} }
}

private struct LiveSmartFundingView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let month: String; let onSaved: () async -> Void
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
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var search = ""
    @State private var filter = TransactionBrowserFilter()
    @State private var rows: [APITransaction] = []
    @State private var nextCursor: String?
    @State private var totalCount = 0
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showFilters = false
    @State private var showAdd = false
    @State private var showSchedule = false
    @State private var transferPresentation: TransferPresentation?
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showTagPrompt = false
    @State private var bulkTag = ""
    private var queryKey: String { "\(search)|\(filter)" }
    var body: some View {
        List {
            Section("Planning") { NavigationLink { LiveScheduledTransactionsView() } label: { Label("Scheduled transactions", systemImage: "calendar.badge.clock") } }
            Section("Posted activity") {
                if rows.isEmpty && !loading && errorMessage == nil { ContentUnavailableView("No matching transactions", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try changing your search or filters.")) }
                ForEach(rows) { transaction in
                    if selecting {
                        bulkRow(transaction)
                    } else { LiveTransactionLink(transaction: transaction, allowsQuickClearing: true) { await load(reset: true) } }
                }
                if let errorMessage { VStack(alignment: .leading, spacing: 8) { Text(errorMessage).foregroundStyle(.secondary); Button("Retry") { Task { await load(reset: true) } } } }
                else if nextCursor != nil { Button { Task { await load(reset: false) } } label: { HStack { Spacer(); if loading { ProgressView() } else { Text("Load more") }; Spacer() } }.disabled(loading) }
                else if !rows.isEmpty { Text("Showing \(rows.count) of \(totalCount)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
        }
            .searchable(text: $search, prompt: "Payee, memo, flag, or tag")
            .navigationTitle("Activity")
            .toolbar { if store.budget.can("edit_transaction") { Button(selecting ? "Done" : "Select") { selecting.toggle(); if !selecting { selectedIDs.removeAll() } }.accessibilityIdentifier("bulk-select-action") }; Button { showFilters = true } label: { Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }.accessibilityLabel("Filter transactions").accessibilityIdentifier("transaction-filter-action"); if !selecting && (store.budget.can("create_transaction") || store.budget.can("manage_planning")) { Menu { if store.budget.can("create_transaction") { Button("Transaction", systemImage: "cart") { showAdd = true }; Button("Transfer", systemImage: "arrow.left.arrow.right") { transferPresentation = TransferPresentation() } }; if store.budget.can("manage_planning") { Button("Schedule Transaction", systemImage: "calendar.badge.plus") { showSchedule = true }.accessibilityIdentifier("schedule-transaction-action") } } label: { Image(systemName: "plus") }.accessibilityIdentifier("add-activity-action") } }
            .safeAreaInset(edge: .bottom) { if selecting { bulkBar } }
            .alert("Add tag", isPresented: $showTagPrompt) { TextField("Tag", text: $bulkTag); Button("Apply") { Task { await bulkUpdate(action: "add_tags", tags: [bulkTag]) } }.disabled(bulkTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("Cancel", role: .cancel) {} } message: { Text("The tag will be added to all selected transactions.") }
            .sheet(isPresented: $showAdd) { entry }
            .sheet(isPresented: $showSchedule) { LiveScheduledTransactionEditor(schedule: nil, currencyCode: store.budget.currencyCode) }
            .sheet(item: $transferPresentation) { presentation in transfer(presentation) }
            .sheet(isPresented: $showFilters) { TransactionFilterView(current: filter) { filter = $0 } }
            .task(id: queryKey) { if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }; guard !Task.isCancelled else { return }; await load(reset: true) }
            .refreshable { await store.refresh(); await load(reset: true) }
    }
    @ViewBuilder private func transfer(_ presentation: TransferPresentation) -> some View {
        LiveTransferView(presentation: presentation, budget: store.budget, accounts: store.accounts, onSaved: reload)
    }
    @ViewBuilder private var entry: some View {
        TransactionEntryView(budget: store.budget, accounts: store.accounts, categories: store.categories, onSaved: reload)
    }
    private func reload() async { await store.refresh(); await load(reset: true) }
    private func bulkRow(_ transaction: APITransaction) -> some View {
        let title = transaction.payeeName.isEmpty ? "Transaction" : transaction.payeeName
        let amount = store.format(transaction.amountMinor)
        return Button { toggleSelection(transaction) } label: {
            HStack {
                Image(systemName: selectedIDs.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                    Text(title)
                    Text(transaction.occurredOn).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(amount).monospacedDigit()
            }
        }
        .disabled(!canBulkEdit(transaction))
        .accessibilityIdentifier("bulk-transaction-row-\(transaction.id)")
    }
    private func canBulkEdit(_ transaction: APITransaction) -> Bool { !transaction.isReconciled && transaction.transferID == nil && transaction.scheduledTransactionID == nil && !["Starting Balance", "Reconciliation adjustment"].contains(transaction.payeeName) }
    private func toggleSelection(_ transaction: APITransaction) { if selectedIDs.contains(transaction.id) { selectedIDs.remove(transaction.id) } else { selectedIDs.insert(transaction.id) } }
    @ViewBuilder private var bulkBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu("Update") {
                Button("Mark Cleared") { Task { await bulkUpdate(action: "set_cleared", cleared: true) } }
                Button("Mark Uncleared") { Task { await bulkUpdate(action: "set_cleared", cleared: false) } }
                Menu("Set Flag") { ForEach(["red", "orange", "yellow", "green", "blue", "purple"], id: \.self) { color in Button(color.capitalized) { Task { await bulkUpdate(action: "set_flag", flag: color) } } }; Button("Remove Flag") { Task { await bulkUpdate(action: "set_flag") } } }
                Button("Add Tag") { bulkTag = ""; showTagPrompt = true }
            }.disabled(selectedIDs.isEmpty || loading).accessibilityIdentifier("bulk-update-menu")
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
    }
    private func bulkUpdate(action: String, cleared: Bool? = nil, flag: String? = nil, tags: [String]? = nil) async { loading = true; defer { loading = false }; do { try await store.bulkUpdateTransactions(.init(transactionIDs: selectedIDs.sorted(), action: action, cleared: cleared, flag: flag, tags: tags)); selectedIDs.removeAll(); selecting = false; await load(reset: true); errorMessage = nil } catch { errorMessage = error.localizedDescription } }
    private func load(reset: Bool) async {
        if loading && !reset { return }; loading = true; defer { loading = false }
        do { let page = try await store.browseTransactions(filter.query(search: search, currencyCode: store.budget.currencyCode, cursor: reset ? nil : nextCursor)); rows = reset ? page.items : rows + page.items; nextCursor = page.nextCursor; totalCount = page.totalCount; errorMessage = nil }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct TransactionBrowserFilter: Equatable, CustomStringConvertible {
    var accountID = ""; var categoryID = ""; var payeeID = ""; var payeeName = ""; var memberID = ""
    var type = "all"; var status = "all"; var lifecycle = "all"; var sort = "date_desc"; var linkage = "all"
    var flag = ""; var tag = ""; var minimum = ""; var maximum = ""
    var usesStartDate = false; var startDate = Date(); var usesEndDate = false; var endDate = Date()
    var isEmpty: Bool { accountID.isEmpty && categoryID.isEmpty && payeeID.isEmpty && memberID.isEmpty && type == "all" && status == "all" && lifecycle == "all" && sort == "date_desc" && linkage == "all" && flag.isEmpty && tag.isEmpty && minimum.isEmpty && maximum.isEmpty && !usesStartDate && !usesEndDate }
    var description: String { [accountID, categoryID, payeeID, memberID, type, status, lifecycle, sort, linkage, flag, tag, minimum, maximum, String(usesStartDate), BudgetWorkspaceStore.dateString(startDate), String(usesEndDate), BudgetWorkspaceStore.dateString(endDate)].joined(separator: "|") }
    func query(search: String, currencyCode: String, cursor: String?) -> APITransactionQuery {
        APITransactionQuery(search: search, accountIDs: accountID.isEmpty ? [] : [accountID], categoryIDs: categoryID.isEmpty ? [] : [categoryID], payeeIDs: payeeID.isEmpty ? [] : [payeeID], startDate: usesStartDate ? BudgetWorkspaceStore.dateString(startDate) : nil, endDate: usesEndDate ? BudgetWorkspaceStore.dateString(endDate) : nil, minimumAmountMinor: minimum.isEmpty ? nil : CurrencyText.parseMinorUnits(minimum, currencyCode: currencyCode), maximumAmountMinor: maximum.isEmpty ? nil : CurrencyText.parseMinorUnits(maximum, currencyCode: currencyCode), transactionType: type == "all" ? nil : type, lifecycleStatuses: lifecycle == "all" ? [] : [lifecycle], cleared: status == "cleared" ? true : status == "uncleared" ? false : nil, reconciled: status == "reconciled" ? true : nil, flags: flag.isEmpty ? [] : [flag], tags: tag.isEmpty ? [] : [tag], actorUserIDs: memberID.isEmpty ? [] : [memberID], isTransfer: linkage == "transfer" ? true : nil, isScheduledRealization: linkage == "scheduled" ? true : nil, sort: sort, limit: 50, cursor: cursor)
    }
}

private struct TransactionFilterView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TransactionBrowserFilter
    @State private var showPayeeSelector = false
    let onApply: (TransactionBrowserFilter) -> Void
    init(current: TransactionBrowserFilter, onApply: @escaping (TransactionBrowserFilter) -> Void) { _draft = State(initialValue: current); self.onApply = onApply }
    var body: some View { NavigationStack { Form {
        Section("Resources") { Picker("Account", selection: $draft.accountID) { Text("All accounts").tag(""); ForEach(store.accounts) { Text($0.name).tag($0.id) } }; Picker("Category", selection: $draft.categoryID) { Text("All categories").tag(""); ForEach(store.categories) { Text($0.name).tag($0.id) } }; Button { showPayeeSelector = true } label: { LabeledContent("Payee", value: draft.payeeName.isEmpty ? "All payees" : draft.payeeName) }.accessibilityIdentifier("activity-payee-selector"); if !draft.payeeID.isEmpty { Button("Clear Payee Filter", role: .destructive) { draft.payeeID = ""; draft.payeeName = "" } }; if !store.householdMembers.isEmpty { Picker("Member", selection: $draft.memberID) { Text("All authorized members").tag(""); ForEach(store.householdMembers) { Text($0.displayName).tag($0.userID) } } } }
        Section("Transaction") { Picker("Type", selection: $draft.type) { Text("All types").tag("all"); Text("Spending").tag("spending"); Text("Income").tag("income"); Text("Refund").tag("refund"); Text("Transfer").tag("transfer") }; Picker("Clearing", selection: $draft.status) { Text("Any clearing state").tag("all"); Text("Cleared").tag("cleared"); Text("Uncleared").tag("uncleared"); Text("Reconciled").tag("reconciled") }; Picker("Lifecycle", selection: $draft.lifecycle) { Text("Any lifecycle").tag("all"); Text("Posted").tag("posted"); Text("Voided").tag("voided"); Text("Reversal").tag("reversal") }; Picker("Source", selection: $draft.linkage) { Text("Any source").tag("all"); Text("Transfers").tag("transfer"); Text("Realized schedules").tag("scheduled") }; TextField("Flag", text: $draft.flag); TextField("Tag", text: $draft.tag) }
        Section("Date range") { Toggle("Starting date", isOn: $draft.usesStartDate); if draft.usesStartDate { DatePicker("From", selection: $draft.startDate, displayedComponents: .date) }; Toggle("Ending date", isOn: $draft.usesEndDate); if draft.usesEndDate { DatePicker("Through", selection: $draft.endDate, displayedComponents: .date) } }
        Section("Signed amount") { CurrencyAmountField("Minimum", text: $draft.minimum, currencyCode: store.budget.currencyCode, allowsNegative: true, allowsZero: true); CurrencyAmountField("Maximum", text: $draft.maximum, currencyCode: store.budget.currencyCode, allowsNegative: true, allowsZero: true); Text("Outflows are negative; inflows are positive.").font(.caption).foregroundStyle(.secondary) }
        Section("Sort") { Picker("Order", selection: $draft.sort) { Text("Newest first").tag("date_desc"); Text("Oldest first").tag("date_asc"); Text("Largest amount").tag("amount_desc"); Text("Smallest amount").tag("amount_asc"); Text("Payee A–Z").tag("payee_asc") } }
        Section { Button("Reset filters") { draft = TransactionBrowserFilter() } }
    }.navigationTitle("Filter Activity").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Apply") { onApply(draft); dismiss() } } }.sheet(isPresented: $showPayeeSelector) { PayeeSearchSelectionView(title: "Filter by Payee") { payee in draft.payeeID = payee.id; draft.payeeName = payee.displayName } } } }
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
            ScheduledActivityPresentation(name: item.name, amountMinor: item.amountMinor, occurrenceDate: item.nextDate, context: item.isActive ? "\(accountName(item.accountID)) · \(recurrence)" : "Paused · no forecast or realization")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.isActive ? "active" : "paused"), \(kind.rawValue), \(store.format(item.amountMinor)), \(recurrence), next \(item.nextDate)")
    }
    private func accountName(_ id: String) -> String { store.accounts.first(where: { $0.id == id })?.name ?? "Account" }
}

private struct ScheduledActivityPresentation: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let name: String
    let amountMinor: Int64
    let occurrenceDate: String
    let context: String?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.medium)
                if let context, !context.isEmpty { Text(context).font(.caption).foregroundStyle(.secondary) }
                Text("Scheduled \(BudgetWorkspaceStore.compactDate(occurrenceDate))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.format(amountMinor)).monospacedDigit()
        }
    }
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
    @State private var payeeID: String?
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
        _kind = State(initialValue: inferred); _accountID = State(initialValue: schedule?.accountID ?? ""); _destinationAccountID = State(initialValue: schedule?.destinationAccountID ?? ""); _categoryID = State(initialValue: schedule?.categoryID ?? ""); _payeeID = State(initialValue: schedule?.payeeID); _name = State(initialValue: schedule?.name ?? ""); _amount = State(initialValue: CurrencyText.editable(abs(schedule?.amountMinor ?? 0), currencyCode: currencyCode)); _nextDate = State(initialValue: schedule.map { BudgetWorkspaceStore.parseDate($0.nextDate) } ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!); _recurrenceUnit = State(initialValue: schedule?.recurrenceUnit ?? "months"); _intervalCount = State(initialValue: schedule?.intervalCount ?? 1); _memo = State(initialValue: schedule?.memo ?? ""); _active = State(initialValue: schedule?.isActive ?? true)
    }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: store.budget.currencyCode), value > 0 else { return nil }; return value }
    private var due: Bool { schedule?.isActive == true && Calendar.current.startOfDay(for: nextDate) <= Calendar.current.startOfDay(for: Date()) }
    private var valid: Bool { parsed != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !accountID.isEmpty && (kind != .expense || !categoryID.isEmpty) && (kind != .transfer || !destinationAccountID.isEmpty && destinationAccountID != accountID) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    Picker("Type", selection: $kind) { ForEach(ScheduledKind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) } }.onChange(of: kind) { _, value in if value == .transfer { categoryID = "" } else { destinationAccountID = "" } }
                    TextField("Payee or description", text: $name).onChange(of: name) { _, value in if value != schedule?.name { payeeID = nil } }
                    Picker("Account", selection: $accountID) { Text("Select account").tag(""); ForEach(store.accounts.filter { !$0.isClosed }) { Text($0.name).tag($0.id) } }
                    if kind == .transfer { Picker("Destination", selection: $destinationAccountID) { Text("Select account").tag(""); ForEach(store.accounts.filter { !$0.isClosed && $0.id != accountID }) { Text($0.name).tag($0.id) } } }
                    else if kind == .expense { Picker("Category", selection: $categoryID) { Text("Select category").tag(""); ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } } }
                    CurrencyAmountField("Amount", text: $amount, currencyCode: store.budget.currencyCode)
                    TextField("Memo", text: $memo, axis: .vertical)
                }
                Section("Schedule") {
                    DatePicker("Next occurrence", selection: $nextDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        .accessibilityIdentifier("schedule-next-date")
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
            .alert(schedule == nil ? "Unable to create schedule" : "Unable to update schedule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "Unknown error") }
        }
    }
    private func payload(isActive: Bool? = nil) -> ScheduleOperation { .init(accountID: accountID, destinationAccountID: kind == .transfer ? destinationAccountID : nil, categoryID: kind == .expense ? categoryID : nil, payeeID: kind == .transfer ? nil : payeeID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), amountMinor: kind == .expense ? -(parsed ?? 0) : parsed ?? 0, nextDate: BudgetWorkspaceStore.dateString(nextDate), recurrenceUnit: recurrenceUnit, intervalCount: recurrenceUnit == "once" ? 1 : intervalCount, memo: memo, isActive: isActive ?? active) }
    private func save() async { saving = true; defer { saving = false }; do { if let schedule { try await store.updateSchedule(id: schedule.id, operation: payload()) } else { try await store.createSchedule(payload()) }; dismiss() } catch { self.error = error.localizedDescription } }
    private func remove() async { guard let schedule else { return }; saving = true; defer { saving = false }; do { try await store.deleteSchedule(id: schedule.id); dismiss() } catch { self.error = error.localizedDescription } }
    private func realize() async { guard let schedule else { return }; saving = true; defer { saving = false }; do { _ = try await store.realizeSchedule(id: schedule.id); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct LiveTransactionLink: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let transaction: APITransaction
    var allowsQuickClearing = false
    var onClearingChanged: (() async -> Void)? = nil
    @State private var changingCleared = false
    @State private var clearingError: String?
    var body: some View {
        NavigationLink { LiveTransactionDetailView(transactionID: transaction.id) } label: {
            HStack { VStack(alignment: .leading) { HStack(spacing: 5) { if transaction.flag != nil { Image(systemName: "flag.fill").foregroundStyle(flagColor) }; Text(transaction.payeeName.isEmpty ? "No payee" : transaction.payeeName); if transaction.status == "voided" { Text("VOIDED").font(.caption2.bold()).foregroundStyle(.red).accessibilityIdentifier("transaction-posting-voided-\(transaction.id)") } else if transaction.status == "reversal" { Text("REVERSAL").font(.caption2.bold()).foregroundStyle(.orange).accessibilityIdentifier("transaction-posting-reversal-\(transaction.id)") } }; Text(secondaryText).font(.caption).foregroundStyle(.secondary); if let tags = transaction.tags, !tags.isEmpty { Text(tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }; Spacer(); Text(store.format(transaction.amountMinor)).monospacedDigit() }
        }
        .accessibilityIdentifier("transaction-row-\(transaction.id)")
        .accessibilityValue(transaction.isReconciled ? "Reconciled" : transaction.isCleared ? "Cleared" : "Uncleared")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if allowsQuickClearing && store.canQuickSetCleared(transaction) {
                Button(transaction.isCleared ? "Unclear" : "Clear", systemImage: transaction.isCleared ? "circle" : "checkmark.circle.fill") {
                    Task { await changeCleared(to: !transaction.isCleared) }
                }
                .tint(transaction.isCleared ? .orange : .green)
                .disabled(changingCleared)
                .accessibilityIdentifier("quick-clear-\(transaction.id)")
            }
        }
        .alert("Unable to update clearing status", isPresented: Binding(get: { clearingError != nil }, set: { if !$0 { clearingError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(clearingError ?? "Unknown error") }
    }
    private func changeCleared(to cleared: Bool) async {
        guard !changingCleared else { return }
        changingCleared = true
        defer { changingCleared = false }
        do {
            try await store.setTransactionCleared(id: transaction.id, cleared: cleared)
            await onClearingChanged?()
        } catch { clearingError = error.localizedDescription }
    }
    private var flagColor: Color { switch transaction.flag { case "red": .red; case "orange": .orange; case "yellow": .yellow; case "green": .green; case "blue": .blue; case "purple": .purple; default: .secondary } }
    private var secondaryText: String {
        if let transferID = transaction.transferID,
           let counterpart = store.transactions.first(where: { $0.transferID == transferID && $0.id != transaction.id }),
           let account = store.accounts.first(where: { $0.id == counterpart.accountID }) {
            return "\(transaction.amountMinor < 0 ? "To" : "From") \(account.name) · \(BudgetWorkspaceStore.compactDate(transaction.occurredOn))"
        }
        let category = store.categoryName(transaction)
        return [category, BudgetWorkspaceStore.compactDate(transaction.occurredOn)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct LiveTransactionDetailView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let transactionID: String
    @State private var showEdit = false
    @State private var editTransfer: TransferPresentation?
    @State private var confirmDelete = false
    @State private var confirmDuplicate = false
    @State private var showVoid = false
    @State private var showRecurring = false
    @State private var isDeleting = false
    var transaction: APITransaction? { store.transactions.first(where: { $0.id == transactionID }) }
    var body: some View {
        List {
            if let transaction {
                Section { Text(store.format(transaction.amountMinor)).font(.largeTitle.bold()).frame(maxWidth: .infinity).padding() }
                Section("Details") { LabeledContent("Payee", value: transaction.payeeName); if let linked = linkedAccountName(for: transaction) { LabeledContent("Linked account", value: linked) } else { LabeledContent("Category", value: store.categoryName(transaction)) }; LabeledContent("Date", value: transaction.occurredOn); LabeledContent("Posting") { Text((transaction.status ?? "posted").uppercased()).accessibilityIdentifier("transaction-posting-status") }; LabeledContent("Clearing") { Text(transaction.isReconciled ? "Reconciled" : transaction.isCleared ? "Cleared" : "Uncleared").accessibilityIdentifier("transaction-status") }; LabeledContent("Memo", value: transaction.memo.isEmpty ? "—" : transaction.memo); LabeledContent("Flag", value: transaction.flag?.capitalized ?? "None"); LabeledContent("Tags", value: transaction.tags?.isEmpty == false ? transaction.tags!.map { "#\($0)" }.joined(separator: " ") : "None") }
                if transaction.status == "voided" { Section("Void audit") { LabeledContent("Reason", value: transaction.voidReason ?? "No reason supplied"); if let reversal = transaction.reversalTransactionID { NavigationLink("Open reversal") { LiveTransactionDetailView(transactionID: reversal) } } } }
                if transaction.status == "reversal", let original = transaction.reversalOfTransactionID { Section("Reversal audit") { NavigationLink("Open voided original") { LiveTransactionDetailView(transactionID: original) } } }
                TransactionAttachmentsView(transaction: transaction)
                if transaction.transferID != nil && transaction.isReconciled { Section { Label("This transfer includes reconciled history and cannot be edited or deleted.", systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary) } }
            }
        }.navigationTitle(transaction?.transferID == nil ? "Transaction" : "Transfer Detail").toolbar {
            if let transaction, !transaction.isReconciled, (transaction.status ?? "posted") == "posted" {
                if let transfer = transferPresentation(for: transaction) {
                    Menu {
                        if store.budget.can("edit_transaction") { Button("Edit Transfer", systemImage: "pencil") { editTransfer = transfer }.accessibilityIdentifier("edit-transfer-action") }
                        if store.budget.can("delete_transaction") { Button("Delete Transfer", systemImage: "trash", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("delete-transfer-action") }
                    } label: { Image(systemName: "ellipsis.circle") }
                } else if transaction.transferID == nil {
                    Menu {
                        if store.budget.can("edit_transaction") { Button("Edit", systemImage: "pencil") { showEdit = true } }
                        if store.budget.can("create_transaction"), transaction.scheduledTransactionID == nil, !["Starting Balance", "Reconciliation adjustment"].contains(transaction.payeeName) { Button("Duplicate", systemImage: "plus.square.on.square") { confirmDuplicate = true }.accessibilityIdentifier("duplicate-transaction-action") }
                        if store.budget.can("manage_planning"), transaction.splits.isEmpty, !["Starting Balance", "Reconciliation adjustment"].contains(transaction.payeeName) { Button("Make Recurring", systemImage: "repeat") { showRecurring = true }.accessibilityIdentifier("make-recurring-action") }
                        if store.budget.can("delete_transaction"), !["Starting Balance", "Reconciliation adjustment"].contains(transaction.payeeName) { Button("Void with Reversal", systemImage: "arrow.uturn.backward.circle") { showVoid = true }.accessibilityIdentifier("void-transaction-action") }
                        if store.budget.can("delete_transaction") { Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
            .sheet(isPresented: $showEdit) { if let transaction { LiveTransactionEditView(budget: store.budget, transaction: transaction, accounts: store.accounts, categories: store.categories, onSaved: reload) } }
            .sheet(item: $editTransfer) { LiveTransferView(presentation: $0, budget: store.budget, accounts: store.accounts, onSaved: reload) }
            .sheet(isPresented: $showVoid) { if let transaction { TransactionVoidView(transaction: transaction) } }
            .sheet(isPresented: $showRecurring) { if let transaction { MakeRecurringView(transaction: transaction) } }
            .confirmationDialog("Duplicate this transaction?", isPresented: $confirmDuplicate, titleVisibility: .visible) { Button("Duplicate Transaction") { Task { await duplicateTransaction() } }; Button("Cancel", role: .cancel) {} } message: { Text("A new uncleared copy dated today will post through the normal accounting engine. Attachments are not copied.") }
            .confirmationDialog(transaction?.transferID == nil ? "Delete this transaction?" : "Delete this transfer?", isPresented: $confirmDelete, titleVisibility: .visible) { Button(transaction?.transferID == nil ? "Delete Transaction" : "Delete Transfer", role: .destructive) { Task { await deleteTransaction() } }; Button("Cancel", role: .cancel) {} } message: { Text(transaction?.transferID == nil ? "This cannot be undone and will immediately update the plan and reports." : "Both linked account entries will be removed atomically. Your plan and categories will not change.") }
    }
    private func reload() async { await store.refresh() }
    private func linkedAccountName(for transaction: APITransaction) -> String? {
        guard let transferID = transaction.transferID,
              let counterpart = store.transactions.first(where: { $0.transferID == transferID && $0.id != transaction.id }) else { return nil }
        return store.accounts.first(where: { $0.id == counterpart.accountID })?.name
    }
    private func transferPresentation(for transaction: APITransaction) -> TransferPresentation? {
        guard let transferID = transaction.transferID,
              let counterpart = store.transactions.first(where: { $0.transferID == transferID && $0.id != transaction.id }) else { return nil }
        let source = transaction.amountMinor < 0 ? transaction : counterpart
        let destination = transaction.amountMinor > 0 ? transaction : counterpart
        guard source.amountMinor < 0, destination.amountMinor > 0 else { return nil }
        return TransferPresentation(transferID: transferID, sourceID: source.accountID, destinationID: destination.accountID, amount: CurrencyText.editable(-source.amountMinor, currencyCode: store.budget.currencyCode), memo: source.memo, date: BudgetWorkspaceStore.parseDate(source.occurredOn), cleared: source.isCleared && destination.isCleared)
    }
    private func deleteTransaction() async {
        guard let transaction else { return }
        isDeleting = true; defer { isDeleting = false }
        do { if let transferID = transaction.transferID { try await store.deleteTransfer(id: transferID) } else { try await store.deleteTransaction(id: transaction.id) }; dismiss() }
        catch { store.errorMessage = error.localizedDescription }
    }
    private func duplicateTransaction() async {
        guard let transaction else { return }
        isDeleting = true; defer { isDeleting = false }
        do { try await store.duplicateTransaction(id: transaction.id, occurredOn: BudgetWorkspaceStore.dateString(Date())) }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private struct TransactionVoidView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let transaction: APITransaction
    @State private var reason = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View { NavigationStack { Form { Section { Text("The original posting remains visible and a current-dated reversal exactly compensates it. This cannot be undone.").foregroundStyle(.secondary); TextField("Reason (optional)", text: $reason, axis: .vertical).accessibilityIdentifier("void-reason") } }.navigationTitle("Void Transaction").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Void & Reverse", role: .destructive) { Task { await save() } }.disabled(saving).accessibilityIdentifier("confirm-void-action") } }.alert("Unable to void", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "Unknown error") } } }
    private func save() async { saving = true; defer { saving = false }; do { try await store.voidTransaction(id: transaction.id, reason: reason); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct MakeRecurringView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let transaction: APITransaction
    @State private var unit = "months"
    @State private var interval = 1
    @State private var nextDate: Date
    @State private var saving = false
    @State private var error: String?
    init(transaction: APITransaction) {
        self.transaction = transaction
        let original = BudgetWorkspaceStore.parseDate(transaction.occurredOn)
        let future = Calendar.current.date(byAdding: .month, value: 1, to: original) ?? Date().addingTimeInterval(2_592_000)
        _nextDate = State(initialValue: max(future, Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
    }
    var body: some View { NavigationStack { Form { Section("Template") { LabeledContent("Payee", value: transaction.payeeName); LabeledContent("Amount", value: store.format(transaction.amountMinor)); Text("The existing posted transaction remains unchanged.").font(.footnote).foregroundStyle(.secondary) }; Section("Recurrence") { Picker("Frequency", selection: $unit) { Text("Days").tag("days"); Text("Weeks").tag("weeks"); Text("Months").tag("months"); Text("Years").tag("years") }; Stepper("Every \(interval) \(unit)", value: $interval, in: 1...365); if unit == "weeks" { Button("Biweekly") { interval = 2 } }; DatePicker("Next occurrence", selection: $nextDate, in: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)..., displayedComponents: .date).accessibilityIdentifier("recurring-next-date") }; Section { Text("Saving creates forecast only. No account, category, or actual Activity value changes until realization.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Make Recurring").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save Schedule") { Task { await save() } }.disabled(saving).accessibilityIdentifier("save-recurring-action") } }.alert("Unable to create schedule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "Unknown error") } } }
    private func save() async { saving = true; defer { saving = false }; do { try await store.createScheduleFromTransaction(id: transaction.id, operation: .init(recurrenceUnit: unit, intervalCount: interval, nextDate: BudgetWorkspaceStore.dateString(nextDate))); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct TransactionAttachmentsView: View {
    private enum PendingSource { case camera, photos, files }
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let transaction: APITransaction
    @State private var attachments: [APITransactionAttachment] = []
    @State private var showingSources = false
    @State private var importingFile = false
    @State private var choosingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var pendingSource: PendingSource?
    @State private var pendingRemoval: APITransactionAttachment?
    @State private var previewURL: URL?
    @State private var error: String?
    var body: some View { Section("Attachments") { if attachments.isEmpty { Text("No attachments").foregroundStyle(.secondary) }; ForEach(attachments) { attachment in HStack(spacing: 12) { Button { Task { await open(attachment) } } label: { VStack(alignment: .leading) { Text(attachment.filename); Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("attachment-preview-\(attachment.id)").accessibilityLabel("Preview \(attachment.filename)"); if store.budget.can("edit_transaction") { Button { pendingRemoval = attachment } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.borderless).foregroundStyle(.red).accessibilityIdentifier("attachment-remove-\(attachment.id)").accessibilityLabel("Remove \(attachment.filename)") } } }; if store.budget.can("edit_transaction"), transaction.status != "reversal", attachments.count < 20 { Button("Add Attachment", systemImage: "paperclip") { showingSources = true }.accessibilityIdentifier("add-attachment-action") }; Text("PDF, JPEG, PNG, or HEIC · 10 MB maximum · detached files retained 30 days").font(.caption).foregroundStyle(.secondary) }
        .task(id: store.liveCredentialRevision) { await load() }
        .confirmationDialog("Add Attachment", isPresented: $showingSources, titleVisibility: .visible) {
            Button("Take Photo", systemImage: "camera") { queue(.camera) }.accessibilityIdentifier("attachment-take-photo")
            Button("Choose Photo", systemImage: "photo.on.rectangle") { queue(.photos) }.accessibilityIdentifier("attachment-choose-photo")
            Button("Choose File", systemImage: "folder") { queue(.files) }.accessibilityIdentifier("attachment-choose-file")
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: showingSources) { _, presented in if !presented { presentQueuedSourceAfterDismissal() } }
        .photosPicker(isPresented: $choosingPhoto, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in guard let item else { return }; Task { await importPhoto(item) } }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.pdf, .jpeg, .png, .heic]) { result in Task { await importFile(result) } }
        .sheet(isPresented: $showingCamera) { AttachmentCameraPicker { image in Task { await importCameraImage(image) } } }
        .navigationDestination(item: $previewURL) { url in AttachmentPreviewController(url: url).navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline) }
        .confirmationDialog("Remove Attachment?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible, presenting: pendingRemoval) { attachment in
            Button("Remove Attachment", role: .destructive) { pendingRemoval = nil; Task { await detach(attachment) } }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { attachment in Text("\(attachment.filename) will be detached and retained for 30 days before permanent deletion.") }
        .alert("Attachment error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "Unknown error") }
    }
    private func load() async {
        do {
            attachments = try await store.transactionAttachments(id: transaction.id)
            error = nil
        } catch is CancellationError {
            // Credential rotation cancels the stale load and immediately starts one with the current token.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports task cancellation through URLError on some OS releases.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    private func importFile(_ result: Result<URL, Error>) async { do { let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; let values = try url.resourceValues(forKeys: [.contentTypeKey]); let data = try Data(contentsOf: url, options: .mappedIfSafe); try await upload(data: data, filename: url.lastPathComponent, contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream") } catch { self.error = error.localizedDescription } }
    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw workspaceRepositoryError("The selected photo could not be read.") }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .heic) || $0.conforms(to: .jpeg) || $0.conforms(to: .png) }) ?? .jpeg
            try await upload(data: data, filename: "photo-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "jpg")", contentType: type.preferredMIMEType ?? "image/jpeg")
        } catch { self.error = error.localizedDescription }
    }
    private func importCameraImage(_ image: UIImage) async {
        do {
            guard let data = image.jpegData(compressionQuality: 0.9) else { throw workspaceRepositoryError("The captured photo could not be encoded.") }
            try await upload(data: data, filename: "camera-\(UUID().uuidString).jpg", contentType: "image/jpeg")
        } catch { self.error = error.localizedDescription }
    }
    private func upload(data: Data, filename: String, contentType: String) async throws {
        guard data.count <= 10 * 1024 * 1024 else { throw workspaceRepositoryError("Attachments must be 10 MB or smaller.") }
        try await store.uploadTransactionAttachment(id: transaction.id, filename: filename, contentType: contentType, data: data)
        await load()
    }
    private func queue(_ source: PendingSource) {
        pendingSource = source
        showingSources = false
    }
    private func presentQueuedSourceAfterDismissal() {
        guard let source = pendingSource else { return }
        Task { @MainActor in
            // A confirmation dialog remains in UIKit's dismissal transition briefly after its
            // binding becomes false. Wait for that transition before presenting another modal.
            try? await Task.sleep(for: .milliseconds(350))
            guard pendingSource != nil, !showingSources else { return }
            pendingSource = nil
            switch source {
            case .camera: requestCamera()
            case .photos: choosingPhoto = true
            case .files: importingFile = true
            }
        }
    }
    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { error = "Camera is not available on this device."; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showingCamera = true
        case .notDetermined:
            Task { if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true } else { error = "Camera access was denied. You can enable it in Settings or choose an existing photo or file." } }
        case .denied, .restricted: error = "Camera access is unavailable. You can enable it in Settings or choose an existing photo or file."
        @unknown default: error = "Camera access is unavailable. Choose an existing photo or file."
        }
    }
    private func open(_ attachment: APITransactionAttachment) async { do { let data = try await store.downloadTransactionAttachment(transactionID: transaction.id, attachmentID: attachment.id); let directory = FileManager.default.temporaryDirectory.appending(path: "BudgetAttachmentPreview", directoryHint: .isDirectory); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let url = directory.appending(path: attachment.filename); try data.write(to: url, options: .atomic); previewURL = url } catch { self.error = error.localizedDescription } }
    private func detach(_ attachment: APITransactionAttachment) async { do { try await store.detachTransactionAttachment(transactionID: transaction.id, attachmentID: attachment.id); await load() } catch { self.error = error.localizedDescription } }
}

private struct AttachmentPreviewController: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct AttachmentCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: AttachmentCameraPicker
        init(parent: AttachmentCameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }
    }
}

private struct LiveAccountsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showAdd = false
    private var activation: FreshBudgetActivationState {
        .init(accountCount: store.accounts.count, groupCount: store.groups.count, categoryCount: store.categories.count,
              canManageStructure: store.budget.can("manage_budget_structure"))
    }
    var body: some View {
        List {
            ForEach(store.accounts) { account in
                NavigationLink { LiveAccountRegisterView(initialAccount: account) } label: {
                    HStack { Label { VStack(alignment: .leading) { Text(account.name); Text(account.accountType.capitalized).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: account.accountType == "credit" ? "creditcard.fill" : "building.columns.fill") }; Spacer(); VStack(alignment: .trailing) { Text(store.format(store.balance(for: account))).monospacedDigit(); Text("Current").font(.caption).foregroundStyle(.secondary) } }
                }
                .accessibilityIdentifier("account-row-\(account.id)")
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
        .sheet(isPresented:$showAdd){AccountCreationView(budget:store.budget,onSaved:reload)}
    }
    private func reload() async { await store.refresh() }
}

struct LiveAccountRegisterView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let initialAccount: APIAccount
    @State private var showAdd = false
    @State private var transferPresentation: TransferPresentation?
    @State private var showReconcile = false
    @State private var showSettings = false

    private var account: APIAccount { store.accounts.first(where: { $0.id == initialAccount.id }) ?? initialAccount }

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
                        LiveTransactionLink(transaction: transaction, allowsQuickClearing: true)
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
                if store.budget.can("create_transaction") { Button("Transfer", systemImage: "arrow.left.arrow.right") { transferPresentation = TransferPresentation(sourceID: account.id) } }
                if store.budget.can("reconcile_account") { Button("Reconcile", systemImage: "checkmark.seal") { showReconcile = true } }
                if store.budget.can("manage_budget_structure") { Button("Account Settings", systemImage: "gearshape") { showSettings = true }.accessibilityIdentifier("account-settings-action") }
            }
        }
        .sheet(isPresented: $showAdd) { entry }
        .sheet(item: $transferPresentation) { presentation in transfer(presentation) }
        .sheet(isPresented: $showReconcile) { reconcile }
        .sheet(isPresented: $showSettings) { AccountSettingsView(account: account) }
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
        TransactionEntryView(budget: store.budget, accounts: store.accounts, categories: store.categories, initialAccountID: account.id, onSaved: store.refresh)
    }
    @ViewBuilder private func transfer(_ presentation: TransferPresentation) -> some View {
        LiveTransferView(presentation: presentation, budget: store.budget, accounts: store.accounts, onSaved: store.refresh)
    }
    @ViewBuilder private var reconcile: some View {
        LiveReconcileView(budget: store.budget, account: account, currentBalance: store.clearedBalance(for: account), onSaved: store.refresh)
    }
}

private struct TransferPresentation: Identifiable {
    let id = UUID()
    let transferID: String?
    let sourceID: String
    let destinationID: String
    let amount: String
    let memo: String
    let date: Date
    let cleared: Bool

    init(transferID: String? = nil, sourceID: String = "", destinationID: String = "", amount: String = "", memo: String = "", date: Date = Date(), cleared: Bool = false) {
        self.transferID = transferID; self.sourceID = sourceID; self.destinationID = destinationID; self.amount = amount; self.memo = memo; self.date = date; self.cleared = cleared
    }
}

#if DEBUG
private final class TransferEditorLifetime: ObservableObject {
    let id: UUID
    init(id: UUID) { self.id = id; print("TRANSFER_EDITOR_INIT id=\(id)") }
    deinit { print("TRANSFER_EDITOR_DEINIT id=\(id)") }
    func log(_ event: String) { print("TRANSFER_\(event) id=\(id)") }
}
#endif

private struct LiveTransferView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let presentation: TransferPresentation
    let budget: APIBudget; let accounts: [APIAccount]; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String
    @State private var destinationID = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var date = Date()
    @State private var cleared = false
    @State private var isSaving = false; @State private var errorMessage: String?
    @FocusState private var memoFocused: Bool
#if DEBUG
    @StateObject private var lifetime: TransferEditorLifetime
#endif

    init(presentation: TransferPresentation, budget: APIBudget, accounts: [APIAccount], onSaved: @escaping () async -> Void) {
        self.presentation = presentation; self.budget = budget; self.accounts = accounts; self.onSaved = onSaved
        _sourceID = State(initialValue: presentation.sourceID)
        _destinationID = State(initialValue: presentation.destinationID); _amount = State(initialValue: presentation.amount); _memo = State(initialValue: presentation.memo); _date = State(initialValue: presentation.date); _cleared = State(initialValue: presentation.cleared)
#if DEBUG
        _lifetime = StateObject(wrappedValue: TransferEditorLifetime(id: presentation.id))
        print("TRANSFER_VIEW_INIT id=\(presentation.id) source=\(presentation.sourceID)")
#endif
    }
    private var openAccounts: [APIAccount] { accounts.filter { !$0.isClosed } }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode), value > 0 else { return nil }; return value }
    var body: some View {
#if DEBUG
        let _ = lifetime.log("BODY source=\(sourceID) destination=\(destinationID) amountLength=\(amount.count) memoLength=\(memo.count) loading=\(workspace.isLoading)")
#endif
        NavigationStack { Form {
            Picker("From", selection: $sourceID) { Text("Select account").tag(""); ForEach(openAccounts) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("transfer-source-account").accessibilityValue(accountName(sourceID))
            Picker("To", selection: $destinationID) { Text("Select account").tag(""); ForEach(openAccounts.filter { $0.id != sourceID }) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("transfer-destination-account").accessibilityValue(accountName(destinationID))
            CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode, onFocusChange: logAmountFocus)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            TextField("Memo", text: $memo).focused($memoFocused)
            Toggle("Cleared", isOn: $cleared)
        }.navigationTitle(presentation.transferID == nil ? "Transfer" : "Edit Transfer").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(parsed == nil || sourceID.isEmpty || destinationID.isEmpty || sourceID == destinationID || isSaving) } }.onAppear {
#if DEBUG
            lifetime.log("APPEAR sheet=\(presentation.id) accounts=\(accounts.count)")
#endif
            if sourceID.isEmpty { sourceID = openAccounts.first?.id ?? "" }; selectDestination()
        }.onDisappear {
#if DEBUG
            lifetime.log("DISAPPEAR sheet=\(presentation.id)")
#endif
        }.onChange(of: sourceID) { _, value in
#if DEBUG
            lifetime.log("SOURCE_CHANGE value=\(value)")
#endif
            selectDestination()
        }.onChange(of: destinationID) { _, value in
#if DEBUG
            lifetime.log("DESTINATION_CHANGE value=\(value)")
#endif
        }.onChange(of: amount) { _, value in
#if DEBUG
            lifetime.log("AMOUNT_CHANGE value=\(value)")
#endif
        }.onChange(of: memo) { _, value in
#if DEBUG
            lifetime.log("MEMO_CHANGE length=\(value.count)")
#endif
        }
#if DEBUG
        .onChange(of: memoFocused) { _, focused in lifetime.log("FOCUS field=memo active=\(focused)") }
        .onChange(of: workspace.isLoading) { _, value in lifetime.log("WORKSPACE_LOADING value=\(value)") }
        .onChange(of: workspace.accounts.count) { _, value in lifetime.log("WORKSPACE_ACCOUNTS count=\(value)") }
#endif
        .alert("Unable to transfer", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
    }
    private func selectDestination() { if destinationID == sourceID || !openAccounts.contains(where: { $0.id == destinationID }) { destinationID = openAccounts.first(where: { $0.id != sourceID })?.id ?? "" } }
    private func logAmountFocus(_ focused: Bool) {
#if DEBUG
        lifetime.log("FOCUS field=amount active=\(focused)")
#endif
    }
    private func accountName(_ id: String) -> String { openAccounts.first(where: { $0.id == id })?.name ?? "Select account" }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { let operation = TransferMoneyOperation(sourceAccountID: sourceID, destinationAccountID: destinationID, amountMinor: parsed, occurredOn: BudgetWorkspaceStore.dateString(date), memo: memo, isCleared: cleared); if let transferID = presentation.transferID { try await workspace.updateTransfer(id: transferID, operation: operation) } else { try await workspace.createTransfer(operation) }; dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LiveCategoryEditView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let category: APICategory; let groups: [APICategoryGroup]; let members: [APIHouseholdMember]; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String; @State private var groupID: String; @State private var sortOrder: Int; @State private var archived: Bool; @State private var delegatedUserID: String; @State private var isSaving = false; @State private var errorMessage: String?; @State private var confirmDelete = false
    init(budget: APIBudget, category: APICategory, groups: [APICategoryGroup], members: [APIHouseholdMember], onSaved: @escaping () async -> Void) {
        self.budget = budget; self.category = category; self.groups = groups; self.members = members; self.onSaved = onSaved
        _name = State(initialValue: category.name); _groupID = State(initialValue: category.groupID); _sortOrder = State(initialValue: category.sortOrder); _archived = State(initialValue: category.isArchived); _delegatedUserID = State(initialValue: category.delegatedUserID ?? "")
    }
    var body: some View { NavigationStack { Form { TextField("Name", text: $name); if categoryNameConflict { Text("A category with this name already exists in the selected group.").font(.footnote).foregroundStyle(.red).accessibilityIdentifier("category-name-conflict") }; Picker("Group", selection: $groupID) { ForEach(groups.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } };Stepper("Order \(sortOrder)",value:$sortOrder,in:0...10_000); if budget.can("manage_allowances") { Picker("Delegated budget", selection: $delegatedUserID) { Text("Household / private").tag(""); ForEach(members.filter { $0.role != "owner" && $0.isActive }) { Text($0.displayName).tag($0.userID) } } }; Toggle("Archived", isOn: $archived); if archived { Text("Archived categories remain in historical reports but are hidden from new spending and assignments.").font(.footnote).foregroundStyle(.secondary) };Section{Button("Delete Unused Category",role:.destructive){confirmDelete=true};Text("Categories with transactions, allocations, targets, or other financial history cannot be deleted. Archive them instead.").font(.footnote).foregroundStyle(.secondary)} }.navigationTitle("Manage Category").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(normalizedCategoryName(name).isEmpty || groupID.isEmpty || isSaving || categoryNameConflict) } }.confirmationDialog("Delete this category?",isPresented:$confirmDelete){Button("Delete Unused Category",role:.destructive){Task{await remove()}}}.alert("Unable to update category", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } } }
    private var categoryNameConflict: Bool { let key=normalizedCategoryName(name); return !key.isEmpty && workspace.categories.contains { $0.id != category.id && $0.groupID == groupID && normalizedCategoryName($0.name) == key } }
    private func save() async { isSaving = true; defer { isSaving = false }; do { try await workspace.updateCategory(id: category.id, value: APICategoryUpdate(groupID: groupID, name: name, sortOrder: sortOrder, isArchived: archived), delegatedUserID: delegatedUserID.isEmpty ? nil : delegatedUserID); dismiss() } catch { errorMessage = error.localizedDescription } }
    private func remove()async{isSaving=true;defer{isSaving=false};do{try await workspace.deleteCategory(id:category.id);dismiss()}catch{errorMessage=error.localizedDescription}}
}

private struct LiveReconcileView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget; let account: APIAccount; let currentBalance: Int64; let onSaved: () async -> Void
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
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showFilters = false
    @State private var breakdownMode = SpendingBreakdownMode.category
    @State private var selectedAngle: Int64?
    @State private var selectedSlice: SpendingBreakdownSlice?
    @State private var showReportPayeeSelector = false
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
            if store.reportCategoryID.isEmpty, store.reportCategoryGroup.isEmpty, store.reportTransactionType.isEmpty, let report = store.incomeReport { IncomeSpendingTrendsView(report: report) }
        }.navigationTitle("Insights").toolbar { Button { showFilters = true } label: { Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") } }.sheet(isPresented: $showFilters) { filters }.navigationDestination(item: $selectedSlice) { slice in if slice.mode == .group { LiveReportGroupView(group: slice.name) } else if let category = store.spendingReport?.categories.first(where: { $0.categoryID == slice.id }) { LiveReportCategoryView(category: category) } }
    }
    private var hasFilters: Bool { !store.reportAccountID.isEmpty || !store.reportCategoryID.isEmpty || !store.reportCategoryGroup.isEmpty || !store.reportPayee.isEmpty || !store.reportMemberID.isEmpty || !store.reportTransactionType.isEmpty || store.reportCleared != "all" || store.includeTrackingAccounts }
    private var filters: some View { NavigationStack { Form {
        Picker("Account", selection: $store.reportAccountID) { Text("All accounts").tag(""); ForEach(store.accounts) { Text($0.name).tag($0.id) } }
        Picker("Category", selection: $store.reportCategoryID) { Text("All categories").tag(""); ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } }
        Picker("Category group", selection: $store.reportCategoryGroup) { Text("All groups").tag(""); ForEach(store.groups) { Text($0.name).tag($0.name) } }
        Button { showReportPayeeSelector = true } label: { LabeledContent("Payee", value: store.reportPayee.isEmpty ? "All payees" : store.reportPayee) }
        if !store.reportPayee.isEmpty { Button("Clear Payee Filter", role: .destructive) { store.reportPayee = "" } }
        if !store.householdMembers.isEmpty { Picker("Member", selection: $store.reportMemberID) { Text("All members").tag(""); ForEach(store.householdMembers.filter(\.isActive)) { Text($0.displayName).tag($0.userID) } } }
        Picker("Type", selection: $store.reportTransactionType) { Text("All types").tag(""); Text("Spending").tag("spending"); Text("Refunds").tag("refund"); Text("Income").tag("income"); Text("Transfers").tag("transfer") }
        Picker("Status", selection: $store.reportCleared) { Text("All statuses").tag("all"); Text("Cleared").tag("cleared"); Text("Uncleared").tag("uncleared") }
        Toggle("Include tracking accounts", isOn: $store.includeTrackingAccounts)
    }.navigationTitle("Report Filters").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Reset") { store.reportAccountID = ""; store.reportCategoryID = ""; store.reportCategoryGroup = ""; store.reportPayee = ""; store.reportMemberID = ""; store.reportTransactionType = ""; store.reportCleared = "all"; store.includeTrackingAccounts = false } }; ToolbarItem(placement: .confirmationAction) { Button("Apply") { showFilters = false; Task { await reload() } } } }.sheet(isPresented: $showReportPayeeSelector) { PayeeSearchSelectionView(title: "Filter by Payee") { store.reportPayee = $0.displayName } } } }
    private func reload() async { await store.refresh() }
}

private struct IncomeSpendingTrendsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIIncomeSpendingReport
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value }()

    var body: some View {
        Section("Income vs. Spending") {
            if !report.periods.isEmpty {
                Chart {
                    ForEach(report.periods) { period in
                        BarMark(x: .value("Month", dateFormatter.date(from: period.periodStart) ?? .distantPast), y: .value("Amount", period.incomeMinor))
                            .foregroundStyle(by: .value("Flow", "Income"))
                        BarMark(x: .value("Month", dateFormatter.date(from: period.periodStart) ?? .distantPast), y: .value("Amount", period.spendingMinor))
                            .foregroundStyle(by: .value("Flow", "Spending"))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(report.periods.count, 6))) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Int64.self) { Text(store.format(amount)).font(.caption2) } } } }
                .frame(minHeight: 220)
                .accessibilityIdentifier("income-spending-trends-chart")
            }
            LabeledContent("Income", value: store.format(report.incomeMinor))
            LabeledContent("Spending", value: store.format(report.spendingMinor))
            LabeledContent("Net cash flow", value: store.format(report.differenceMinor))
            if let rate = report.savingsRate { LabeledContent("Savings rate", value: rate.formatted(.percent.precision(.fractionLength(0)))) }
        }
    }
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
                                    if let policy = delegatedPolicy(for: member.userID) {
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
                Section("Financial organization") {
                    NavigationLink { PayeeManagementView() } label: { Label("Payees", systemImage: "person.text.rectangle") }
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

    private func delegatedPolicy(for userID: String) -> APIDelegatedBudget? {
        store.delegatedBudgets.first { $0.userID == userID }
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
    let budget: APIBudget; let transaction: APITransaction; let accounts: [APIAccount]; let categories: [APICategory]; let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var payee: String; @State private var payeeID: String?; @State private var amount: String; @State private var accountID: String; @State private var categoryID: String; @State private var memo: String; @State private var cleared: Bool; @State private var date: Date; @State private var isInflow: Bool; @State private var isSplit: Bool; @State private var splitRows: [WorkspaceSplitDraft]; @State private var flag: String; @State private var tags: String
    @State private var selectedPayeeName: String; @State private var showPayeeSelector = false
    @State private var isSaving = false; @State private var errorMessage: String?
    init(budget: APIBudget, transaction: APITransaction, accounts: [APIAccount], categories: [APICategory], onSaved: @escaping () async -> Void) {
        self.budget=budget; self.transaction=transaction; self.accounts=accounts; self.categories=categories; self.onSaved=onSaved
        _payee=State(initialValue:transaction.payeeName); _payeeID=State(initialValue:transaction.payeeID); _selectedPayeeName=State(initialValue:transaction.payeeID == nil ? "" : transaction.payeeName); _amount=State(initialValue:CurrencyText.editable(abs(transaction.amountMinor),currencyCode:budget.currencyCode)); _accountID=State(initialValue:transaction.accountID); _categoryID=State(initialValue:transaction.categoryID ?? ""); _memo=State(initialValue:transaction.memo); _cleared=State(initialValue:transaction.isCleared); _date=State(initialValue:Self.parseDate(transaction.occurredOn)); _isInflow=State(initialValue:transaction.amountMinor > 0); _isSplit=State(initialValue:!transaction.splits.isEmpty); _splitRows=State(initialValue:transaction.splits.map { WorkspaceSplitDraft(categoryID:$0.categoryID,amount:CurrencyText.editable(abs($0.amountMinor),currencyCode:budget.currencyCode),memo:$0.memo) }); _flag=State(initialValue:transaction.flag ?? ""); _tags=State(initialValue:(transaction.tags ?? []).joined(separator:", "))
    }
    var body: some View { NavigationStack { Form {
        TextField("Payee",text:$payee).onChange(of:payee){_,value in if payeeID != nil && selectedPayeeName != value { payeeID=nil;selectedPayeeName="" }}; Button("Choose saved payee",systemImage:"person.text.rectangle"){showPayeeSelector=true}.accessibilityIdentifier("saved-payee-menu"); CurrencyAmountField("Amount", text:$amount, currencyCode:budget.currencyCode); Toggle("Income / inflow",isOn:$isInflow); Picker("Account",selection:$accountID){ForEach(accounts.filter{!$0.isClosed}){Text($0.name).tag($0.id)}}; DatePicker("Date",selection:$date,displayedComponents:.date); Toggle("Split across categories",isOn:$isSplit).disabled(isInflow)
        if isSplit { Section("Splits") { ForEach($splitRows) { $row in Picker("Category",selection:$row.categoryID){Text("Select").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}};CurrencyAmountField("Split amount", text:$row.amount, currencyCode:budget.currencyCode, allowsZero:true);TextField("Split memo",text:$row.memo) }; Button("Add split",systemImage:"plus"){splitRows.append(.init())}; if let remaining { LabeledContent("Remaining",value:CurrencyText.editable(remaining,currencyCode:budget.currencyCode)).foregroundStyle(remaining == 0 ? Color.secondary : Color.red) } } } else if !isInflow { Picker("Category",selection:$categoryID){Text("Uncategorized").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}} }
        TextField("Memo",text:$memo); Picker("Flag",selection:$flag){Text("None").tag("");Text("Red").tag("red");Text("Orange").tag("orange");Text("Yellow").tag("yellow");Text("Green").tag("green");Text("Blue").tag("blue");Text("Purple").tag("purple")}; TextField("Tags (comma separated)",text:$tags);Text("Manage attachments from transaction detail.").font(.footnote).foregroundStyle(.secondary);Toggle("Cleared",isOn:$cleared)
    }.navigationTitle("Edit Transaction").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(isSaving || parsed == nil || !splitsValid)} }.alert("Unable to save",isPresented:Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})){Button("OK",role:.cancel){}}message:{Text(errorMessage ?? "Unknown error")}.sheet(isPresented:$showPayeeSelector){PayeeSearchSelectionView{item in payeeID=item.id;payee=item.displayName;selectedPayeeName=item.displayName;if categoryID.isEmpty,let suggested=item.defaultCategoryID{categoryID=suggested}}} } }
    private var parsed:Int64?{guard let value=CurrencyText.parseMinorUnits(amount,currencyCode:budget.currencyCode),value>0 else{return nil};return isInflow ? value : -value}
    private var parsedSplits:[TransactionSplitOperation]?{guard isSplit else{return []};var values:[TransactionSplitOperation]=[];for row in splitRows{guard !row.categoryID.isEmpty,let value=CurrencyText.parseMinorUnits(row.amount,currencyCode:budget.currencyCode),value>=0 else{return nil};values.append(.init(categoryID:row.categoryID,amountMinor:-value,memo:row.memo))};return values}
    private var remaining:Int64?{guard let parsed,let parsedSplits else{return nil};return parsed - parsedSplits.reduce(0){$0+$1.amountMinor}}
    private var splitsValid:Bool{!isSplit || (parsedSplits?.count ?? 0)>=2 && remaining==0}
    private func save() async { guard let parsed,let parsedSplits else{return};isSaving=true;defer{isSaving=false};do{try await workspace.updateTransaction(id:transaction.id,operation:RecordTransactionOperation(accountID:accountID,categoryID:isSplit || isInflow || categoryID.isEmpty ? nil:categoryID,amountMinor:parsed,occurredOn:BudgetWorkspaceStore.dateString(date),payeeName:payee,payeeID:payeeID,memo:memo,isCleared:cleared,splits:parsedSplits,flag:flag.isEmpty ? nil:flag,tags:commaValues(tags),attachmentMetadata:transaction.attachmentMetadata ?? []));dismiss()}catch{errorMessage=error.localizedDescription} }
    private func commaValues(_ value:String)->[String]{value.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}}
    private static func parseDate(_ value:String)->Date{let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd";return formatter.date(from:value) ?? Date()}
}

private struct WorkspaceSplitDraft:Identifiable{let id=UUID();var categoryID="";var amount="";var memo=""}
