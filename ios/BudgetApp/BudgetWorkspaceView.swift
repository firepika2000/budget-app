import BudgetAPI
import BudgetCore
import SwiftUI
import Charts
import UniformTypeIdentifiers
import QuickLook
import PhotosUI
import AVFoundation
import UIKit

enum Theme {
    static let accent = Color.teal
    static let healthy = Color.green
    static let attention = Color.orange
    static let danger = Color.red
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
    @State private var creationConfirmation: String?
    var body: some View {
        List {
            if let creationConfirmation {
                Label("Created \(creationConfirmation)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("payee-created-confirmation")
            }
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
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load(reset: true) } }) {
            PayeeEditorView(payee: nil) { createdName in
                creationConfirmation = createdName
                query = createdName
            }
        }
        .overlay { if loading && rows.isEmpty { ProgressView() } }
    }
    private func load(reset: Bool) async { if !reset && loading { return }; let requestedQuery = query; loading = true; defer { if requestedQuery == query { loading = false } }; do { let page = try await store.searchPayees(query: requestedQuery, includeArchived: true, limit: 20, cursor: reset ? nil : nextCursor); guard requestedQuery == query else { return }; rows = reset ? page.items : rows + page.items; nextCursor = page.nextCursor } catch {} }
}

private struct PayeeEditorView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let payee: APIPayee?
    let onCreated: (String) -> Void
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

    init(payee: APIPayee?, onCreated: @escaping (String) -> Void = { _ in }) {
        self.payee = payee
        self.onCreated = onCreated
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
            else {
                let createdName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try await store.createPayee(.init(displayName: createdName, defaultCategoryID: categoryID.isEmpty ? nil : categoryID))
                onCreated(createdName)
            }
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
    var spending: APISpendingReport?; var spendingTrends: APISpendingTrendsReport?; var income: APIIncomeSpendingReport?; var netWorth: APINetWorthReport?; var debt: APIDebtReport?; var planPerformance: APIPlanPerformanceReport?; var resilience: APIResilienceReport?
    var delegated: APIDelegatedBudget?; var forecast: APIForecast?
    var members: [APIHouseholdMember]; var delegatedBudgets: [APIDelegatedBudget]
    var allocationOperations: [APIAllocationOperation] = []
    var targets: [APICategoryTarget] = []
    var schedules: [APIScheduledTransaction] = []
}

enum WorkspaceReportKind: CaseIterable, Hashable {
    case summary, spending, spendingTrends, income, netWorth, debt, planPerformance, resilience
}

struct WorkspaceReports {
    var spending: APISpendingReport?
    var spendingTrends: APISpendingTrendsReport?
    var income: APIIncomeSpendingReport?
    var netWorth: APINetWorthReport?
    var debt: APIDebtReport?
    var planPerformance: APIPlanPerformanceReport?
    var resilience: APIResilienceReport?
    var summary: APIInsightsSummary?
}

struct WorkspaceReportQuery: Equatable {
    let start: Date; let end: Date; let accountID: String; let categoryID: String
    let categoryGroup: String; let payee: String; let memberID: String
    let transactionType: String; let cleared: String; let flag: String; let tag: String
    let spendingTrendDimension: String
    let includeTracking: Bool
}

struct WorkspaceReportContext: Equatable {
    let query: WorkspaceReportQuery
    let planMonth: Date
    let revision: Int
    let credentialRevision: Int
}

@MainActor
protocol WorkspaceDataSource: AnyObject {
    var budget: APIBudget { get }
    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot
    func coreSnapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot
    func reports(planMonth: Date, query: WorkspaceReportQuery, kinds: Set<WorkspaceReportKind>) async throws -> WorkspaceReports
    func exportReports(report: WorkspaceReportQuery) async throws -> Data
    func debtStrategyProjection(_ request: APIDebtStrategyProjectionRequest) async throws -> APIDebtStrategyProjection
}

extension WorkspaceDataSource {
    func coreSnapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot {
        var value = try await snapshot(planMonth: planMonth, report: report)
        value.spending = nil; value.spendingTrends = nil; value.income = nil
        value.netWorth = nil; value.debt = nil; value.planPerformance = nil; value.resilience = nil
        return value
    }
    // The deterministic adapter computes its reports locally using the same
    // canonical snapshot definitions. Live overrides this with bounded reads.
    func reports(planMonth: Date, query: WorkspaceReportQuery, kinds: Set<WorkspaceReportKind>) async throws -> WorkspaceReports {
        guard !kinds.isEmpty else { return WorkspaceReports() }
        let value = try await snapshot(planMonth: planMonth, report: query)
        return WorkspaceReports(
            spending: kinds.contains(.spending) ? value.spending : nil,
            spendingTrends: kinds.contains(.spendingTrends) ? value.spendingTrends : nil,
            income: kinds.contains(.income) ? value.income : nil,
            netWorth: kinds.contains(.netWorth) ? value.netWorth : nil,
            debt: kinds.contains(.debt) ? value.debt : nil,
            planPerformance: kinds.contains(.planPerformance) ? value.planPerformance : nil,
            resilience: kinds.contains(.resilience) ? value.resilience : nil,
            summary: kinds.contains(.summary) ? APIInsightsSummary(currencyCode: budget.currencyCode,
                netCashFlowMinor: value.income?.differenceMinor ?? 0, netWorthMinor: value.netWorth?.netWorthMinor,
                debtMinor: value.debt?.debtMinor, recordedInterestMonthMinor: value.debt?.recordedInterestMonthMinor,
                expectedMarginMinor: value.resilience?.expectedMarginMinor) : nil
        )
    }
}

@MainActor
protocol WorkspaceCommandRepository: AccountCommandRepository, PlanningCommandRepository, TransactionCommandRepository, TransactionBrowserRepository, ScheduleCommandRepository, PayeeCommandRepository {
    func householdInvitations() async throws -> [APIInvitationSummary]
    func createHouseholdInvitation(_ value: APIInvitationCreate) async throws -> APIInvitationSecret
    func resendHouseholdInvitation(id: String) async throws -> APIInvitationSecret
    func cancelHouseholdInvitation(id: String) async throws
    func removeHouseholdMember(userID: String) async throws
    func householdAccessEvents() async throws -> [APIHouseholdAccessEvent]
    func accessProfile(userID: String) async throws -> APIAccessProfile
    func updateAccessProfile(userID: String, value: APIAccessProfileUpsert) async throws -> APIAccessProfile
    func createCategory(groupID: String, groupName: String, newGroupName: String, name: String, delegatedUserID: String?) async throws
    func createGroup(name: String) async throws
    func createRequest(_ value: APIFinancialRequestCreate) async throws
    func updateCategory(id: String, value: APICategoryUpdate, groupName: String?, existingDelegatedUserID: String?, delegatedUserID: String?) async throws
    func updateGroup(id: String, currentName: String?, value: APICategoryGroupUpdate) async throws
    func deleteGroup(id: String, currentName: String?) async throws
    func deleteCategory(id: String) async throws
    func setCategoryFavorite(id: String, isFavorite: Bool, sortOrder: Int) async throws
    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws
    func deleteTarget(categoryID: String) async throws
    func decideRequest(id: String, decision: String, version: Int, amount: Int64?, sourceCategoryID: String?, note: String) async throws
    func cancelRequest(id: String, version: Int, note: String) async throws
    func reviseRequest(id: String, version: Int, value: APIFinancialRequestCreate) async throws
    func createAllowance(_ value: APIAllowancePlanCreate) async throws
    func setAllowanceActive(id: String, active: Bool) async throws
    func issueAllowance(id: String, issueDate: String, expectedVersion: Int) async throws
    func allowanceIssuances(id: String) async throws -> [APIAllowanceIssuance]
    func smartFundingPreview(month: String) async throws -> APISmartFundingPreview
    func commitSmartFunding(_ preview: APISmartFundingPreview) async throws
    func updateDelegatedPolicy(userID: String, value: APIDelegatedBudgetUpsert) async throws
}

@MainActor
final class DemoWorkspaceDataSource: WorkspaceDataSource {
    let demo: DemoStore
    private var attachmentData: [String: Data] = [:]
    private var debtTermsValues: [String: APIAccountDebtTermsUpsert] = [:]
    private var accessProfiles: [String: APIAccessProfile] = [:]
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
        attachmentData["t1"] = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let restricted = store.persona.isChild
        budget = APIBudget(
            id: "demo-budget", householdID: "demo-household", name: "Rivera Household", currencyCode: "USD",
            effectivePermission: restricted ? .contribute : .owner,
            capabilities: restricted ? ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances", "create_transaction", "edit_transaction", "delete_transaction", "request_money", "move_money", "manage_own_categories"] : nil
        )
        debtTermsValues["visa"] = .init(termsType: "credit_card", annualRateBasisPoints: 2049, rateType: "variable", paymentFrequency: "monthly", minimumPaymentRule: "fixed", minimumPaymentMinor: 4500, dueDay: 18)
        debtTermsValues["mastercard"] = .init(termsType: "credit_card", annualRateBasisPoints: 1899, rateType: "variable", paymentFrequency: "monthly", minimumPaymentRule: "fixed", minimumPaymentMinor: 3500, dueDay: 24)
        debtTermsValues["auto"] = .init(termsType: "installment_loan", annualRateBasisPoints: 625, rateType: "fixed", paymentFrequency: "monthly", scheduledPaymentMinor: 41200, dueDay: 1)
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
        let categoryRows: [APICategory] = try decode(visibleCategories.enumerated().map { index, item in ["id": item.id, "budget_id": budget.id, "group_id": groupIDs[item.group]!, "name": item.name, "sort_order": index, "is_archived": item.isHidden, "system_type": NSNull(), "linked_account_id": NSNull(), "delegated_user_id": item.delegatedTo?.rawValue.lowercased() ?? NSNull(), "is_favorite": item.pinned, "favorite_sort_order": item.pinned ? index : NSNull()] })
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.dateFormat = "yyyy-MM-dd"
        let transactionRows: [APITransaction] = try decode(demo.visibleTransactions.map { item in
            let ids = item.categoryIDs.filter { categoryIDs.contains($0) }
            let splitBase = ids.isEmpty ? 0 : item.amount / Int64(ids.count)
            var remainder = ids.isEmpty ? 0 : item.amount % Int64(ids.count)
            let splits: [[String: Any]] = ids.count > 1 ? ids.enumerated().map { index, id in let extra: Int64 = remainder == 0 ? 0 : (remainder > 0 ? 1 : -1); if remainder != 0 { remainder -= extra }; return ["id": "\(item.id)-\(index)", "category_id": id, "amount_minor": item.categoryAmounts[id] ?? splitBase + extra, "memo": "", "financial_classification": item.splitFinancialClassifications[id] ?? NSNull()] } : []
            return ["id": item.id, "account_id": item.accountID, "category_id": ids.count == 1 ? ids[0] : NSNull(), "payee_id": demo.payees.first(where: { $0.name == item.payee })?.id ?? NSNull(), "amount_minor": item.amount, "occurred_on": dateFormatter.string(from: item.date), "payee_name": item.payee, "memo": item.memo, "financial_classification": item.financialClassification ?? NSNull(), "is_cleared": item.cleared, "is_reconciled": item.reconciled, "created_by_user_id": demo.persona.rawValue.lowercased(), "transfer_id": item.transferID.map { $0 as Any } ?? NSNull(), "scheduled_transaction_id": NSNull(), "flag": item.flag.map { $0 as Any } ?? NSNull(), "tags": item.tags, "attachment_metadata": item.attachmentName.map { [["name": $0]] } ?? [], "status": item.status, "void_reason": item.voidReason ?? NSNull(), "reversal_of_transaction_id": item.reversalOfTransactionID ?? NSNull(), "reversal_transaction_id": item.reversalTransactionID ?? NSNull(), "splits": splits]
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
            && (report.cleared == "all" || (report.cleared == "reconciled" ? item.reconciled : item.cleared == (report.cleared == "cleared")))
            && (report.flag.isEmpty || item.flag == report.flag)
            && (report.tag.isEmpty || item.tags.contains(report.tag.lowercased()))
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
        var trendPeriods: [(Date, Date)] = []
        var trendMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: start))!
        while trendMonth <= report.end {
            let next = Calendar.current.date(byAdding: .month, value: 1, to: trendMonth)!
            trendPeriods.append((max(start, trendMonth), min(report.end, Calendar.current.date(byAdding: .day, value: -1, to: next)!)))
            trendMonth = next
        }
        var trendNames: [String: (String, String?)] = [:], trendTotals: [String: Int64] = [:]
        var trendIDs: [String: [String]] = [:], trendPointTotals: [String: [String: Int64]] = [:], trendPointIDs: [String: [String: [String]]] = [:]
        for item in included where item.transferID == nil && item.amount != 0 {
            for (categoryID, amount) in demo.canonicalCategoryAmounts(for: item) {
                guard let category = visibleCategories.first(where: { $0.id == categoryID }) else { continue }
                let key: String, name: String, group: String?
                switch report.spendingTrendDimension {
                case "group": key = "group:\(category.group)"; name = category.group; group = nil
                case "payee": name = item.payee.isEmpty ? "No payee" : item.payee; key = "payee:\(name.lowercased())"; group = nil
                default: key = category.id; name = category.name; group = category.group
                }
                trendNames[key] = (name, group); trendTotals[key, default: 0] -= amount; trendIDs[key, default: []].append(item.id)
                if let period = trendPeriods.first(where: { item.date >= $0.0 && item.date <= $0.1 }) {
                    let periodKey = dateFormatter.string(from: period.0)
                    trendPointTotals[key, default: [:]][periodKey, default: 0] -= amount
                    trendPointIDs[key, default: [:]][periodKey, default: []].append(item.id)
                }
            }
        }
        let rankedTrendKeys = trendTotals.keys.filter { trendTotals[$0, default: 0] > 0 }.sorted {
            trendTotals[$0, default: 0] == trendTotals[$1, default: 0] ? (trendNames[$0]?.0 ?? $0) < (trendNames[$1]?.0 ?? $1) : trendTotals[$0, default: 0] > trendTotals[$1, default: 0]
        }.prefix(12)
        let trendRows: [[String: Any]] = rankedTrendKeys.map { key in
            ["dimension_id": key, "dimension_name": trendNames[key]!.0, "category_group": trendNames[key]!.1 ?? NSNull(), "spending_minor": trendTotals[key]!, "transaction_ids": Array(Set(trendIDs[key] ?? [])).sorted(), "points": trendPeriods.map { period in let periodKey = dateFormatter.string(from: period.0); return ["period_start": periodKey, "period_end": dateFormatter.string(from: period.1), "spending_minor": trendPointTotals[key]?[periodKey] ?? 0, "transaction_ids": Array(Set(trendPointIDs[key]?[periodKey] ?? [])).sorted()] }]
        }
        let spendingTrends: APISpendingTrendsReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "dimension": report.spendingTrendDimension, "total_spending_minor": trendTotals.values.filter { $0 > 0 }.reduce(0, +), "series": trendRows])
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
        let netWorthAccounts = visibleAccounts.filter { (report.accountID.isEmpty || $0.id == report.accountID) && (report.includeTracking || $0.isOnBudget) }
        let netWorthAccountIDs = Set(netWorthAccounts.map(\.id))
        let netWorthTransactions = demo.visibleTransactions.filter { netWorthAccountIDs.contains($0.accountID) }
        func balance(_ account: DemoAccount, _ asOf: Date) -> Int64 { account.balance - demo.visibleTransactions.filter { $0.accountID == account.id && $0.date > asOf }.reduce(Int64(0)) { $0 + $1.amount } }
        var netWorthPoints: [[String: Any]] = []
        var netWorthMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: start))!
        while netWorthMonth <= report.end {
            let next = Calendar.current.date(byAdding: .month, value: 1, to: netWorthMonth)!
            let asOf = min(report.end, Calendar.current.date(byAdding: .day, value: -1, to: next)!)
            let balances = netWorthAccounts.map { balance($0, asOf) }
            let assets = balances.reduce(Int64(0)) { $0 + max($1, 0) }, liabilities = balances.reduce(Int64(0)) { $0 + min($1, 0) }
            netWorthPoints.append(["as_of": dateFormatter.string(from: asOf), "assets_minor": assets, "liabilities_minor": liabilities, "net_worth_minor": assets + liabilities, "transaction_ids": netWorthTransactions.filter { $0.date <= asOf }.map { $0.id }])
            netWorthMonth = next
        }
        let netWorthRows: [[String: Any]] = netWorthAccounts.map { account in ["account_id": account.id, "account_name": account.name, "account_type": account.kind.rawValue, "is_on_budget": account.isOnBudget, "balance_minor": balance(account, report.end), "transaction_ids": netWorthTransactions.filter { $0.accountID == account.id && $0.date <= report.end }.map { $0.id }] }
        let endBalances = netWorthAccounts.map { balance($0, report.end) }
        let netWorthAssets = endBalances.reduce(Int64(0)) { $0 + max($1, 0) }, netWorthLiabilities = endBalances.reduce(Int64(0)) { $0 + min($1, 0) }
        let netWorth: APINetWorthReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "assets_minor": netWorthAssets, "liabilities_minor": netWorthLiabilities, "net_worth_minor": netWorthAssets + netWorthLiabilities, "points": netWorthPoints, "accounts": netWorthRows])
        // Debt reporting includes visible loans regardless of the Net Worth
        // tracking toggle, matching the production server debt-report contract.
        let debtAccounts = visibleAccounts.filter {
            ["credit", "loan"].contains($0.kind.rawValue)
                && (report.accountID.isEmpty || $0.id == report.accountID)
        }
        let openingDate = Calendar.current.date(byAdding: .day, value: -1, to: start)!
        let openingDebt = debtAccounts.reduce(Int64(0)) { $0 + max(-balance($1, openingDate), 0) }
        let debtAccountIDs = Set(debtAccounts.map(\.id))
        let classifiedInterest = demo.visibleTransactions.filter { debtAccountIDs.contains($0.accountID) && $0.transferID == nil && $0.date <= report.end }.map { item -> (DemoTransaction, Int64) in
            let amount = item.categoryIDs.count > 1
                ? -demo.canonicalCategoryAmounts(for: item).filter { item.splitFinancialClassifications[$0.key] == "interest_charge" }.values.reduce(0, +)
                : (item.financialClassification == "interest_charge" ? -item.amount : 0)
            return (item, amount)
        }.filter { $0.1 != 0 }
        let debtRows: [[String: Any]] = debtAccounts.map { account in ["account_id": account.id, "account_name": account.name, "account_type": account.kind.rawValue, "is_on_budget": account.isOnBudget, "debt_minor": max(-balance(account, report.end), 0), "recorded_interest_minor": classifiedInterest.filter { $0.0.accountID == account.id && $0.0.date >= start && $0.0.date <= report.end }.reduce(Int64(0)) { $0 + $1.1 }] }
        let debtPoints: [[String: Any]] = netWorthPoints.map { point in
            let asOf = dateFormatter.date(from: point["as_of"] as! String)!
            return ["as_of": point["as_of"]!, "debt_minor": debtAccounts.reduce(Int64(0)) { $0 + max(-balance($1, asOf), 0) }]
        }
        let endingDebt = debtRows.reduce(Int64(0)) { $0 + ($1["debt_minor"] as? Int64 ?? 0) }
        let reportCalendar = Calendar(identifier: .gregorian)
        let monthStart = reportCalendar.date(from: reportCalendar.dateComponents([.year, .month], from: report.end))!
        let yearStart = reportCalendar.date(from: reportCalendar.dateComponents([.year], from: report.end))!
        let trailingStart = reportCalendar.date(byAdding: .day, value: -364, to: report.end)!
        func recordedInterest(since value: Date) -> Int64 { classifiedInterest.filter { $0.0.date >= value && $0.0.date <= report.end }.reduce(Int64(0)) { $0 + $1.1 } }
        let debt: APIDebtReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "opening_debt_minor": openingDebt, "debt_minor": endingDebt, "principal_reduction_minor": openingDebt - endingDebt, "recorded_interest_range_minor": recordedInterest(since: start), "recorded_interest_month_minor": recordedInterest(since: monthStart), "recorded_interest_ytd_minor": recordedInterest(since: yearStart), "recorded_interest_trailing_12_minor": recordedInterest(since: trailingStart), "recorded_interest_lifetime_minor": classifiedInterest.reduce(Int64(0)) { $0 + $1.1 }, "interest_tracking_started_on": classifiedInterest.map { $0.0.date }.min().map(dateFormatter.string) ?? NSNull(), "points": debtPoints, "accounts": debtRows])
        let planPerformance: APIPlanPerformanceReport = try decode(["start_date": dateFormatter.string(from: start), "end_date": dateFormatter.string(from: report.end), "currency_code": "USD", "points": [["period_start": month, "period_end": dateFormatter.string(from: report.end), "assigned_minor": visibleCategories.reduce(Int64(0)) { $0 + $1.assigned }, "activity_minor": visibleCategories.reduce(Int64(0)) { $0 + $1.activity }, "spending_minor": max(-visibleCategories.reduce(Int64(0)) { $0 + $1.activity }, 0), "carried_available_minor": visibleCategories.reduce(Int64(0)) { $0 + max($1.available - $1.assigned - $1.activity, 0) }, "available_minor": visibleCategories.reduce(Int64(0)) { $0 + $1.available }, "overspent_minor": visibleCategories.reduce(Int64(0)) { $0 + max(-$1.available, 0) }, "ready_to_assign_minor": demo.isRestricted ? 0 : demo.readyToAssign]]])
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
        }.map { item in ["id": item.id, "budget_id": budget.id, "account_id": item.accountID, "destination_account_id": item.destinationAccountID.map { $0 as Any } ?? NSNull(), "category_id": item.categoryID.map { $0 as Any } ?? NSNull(), "name": item.name, "amount_minor": item.amount, "next_date": item.nextDate, "recurrence_unit": item.recurrenceUnit, "interval_count": item.intervalCount, "memo": item.memo, "financial_classification": item.financialClassification ?? NSNull(), "is_active": item.isActive, "last_realized_on": item.lastRealizedOn.map { $0 as Any } ?? NSNull()] })
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
        let scheduledIncome = demoForecast.occurrences.filter { $0.destinationAccountID == nil && $0.amountMinor > 0 }.reduce(Int64(0)) { $0 + $1.amountMinor }
        let scheduledOutflows = demoForecast.occurrences.filter { $0.destinationAccountID == nil && $0.amountMinor < 0 }.reduce(Int64(0)) { $0 - $1.amountMinor }
        let cashIDs = Set(visibleAccounts.filter { $0.isOnBudget && ["checking", "savings", "cash"].contains($0.kind.rawValue) }.map(\.id))
        let resilience: APIResilienceReport = try decode(["as_of": demoForecast.asOf, "through": demoForecast.through, "currency_code": budget.currencyCode, "cash_buffer_minor": demoForecast.accounts.filter { cashIDs.contains($0.accountID) }.reduce(Int64(0)) { $0 + $1.actualBalanceMinor }, "current_on_budget_minor": demoForecast.actualTotalOnBudgetMinor, "projected_on_budget_minor": demoForecast.projectedTotalOnBudgetMinor, "lowest_projected_on_budget_minor": demoForecast.lowestProjectedTotalMinor, "scheduled_income_minor": scheduledIncome, "scheduled_outflows_minor": scheduledOutflows, "expected_margin_minor": scheduledIncome - scheduledOutflows, "essential_expense_coverage_days": NSNull(), "emergency_fund_coverage_days": NSNull(), "unavailable_metrics": ["essential_expense_coverage_days": "Categories do not yet store authoritative essential-expense classification.", "emergency_fund_coverage_days": "Categories do not yet store authoritative emergency-fund classification."]])
        let members: [APIHouseholdMember] = try decode([
            ["user_id": "demo-owner", "email": "alex@example.test", "display_name": "Alex Rivera", "role": "owner", "is_active": true],
            ["user_id": "demo-member", "email": "sam@example.test", "display_name": "Sam Rivera", "role": "adult", "is_active": true]
        ])
        return WorkspaceSnapshot(accounts: accountRows, accountBalances: Dictionary(uniqueKeysWithValues: accountBalanceRows.map { ($0.accountID, $0) }), categories: categoryRows, groups: groupRows, transactions: transactionRows, summary: summary, payees: payeeRows, requests: requestRows, allowances: [], spending: spending, spendingTrends: spendingTrends, income: income, netWorth: netWorth, debt: debt, planPerformance: planPerformance, resilience: resilience, delegated: delegated, forecast: demoForecast, members: members, delegatedBudgets: [], allocationOperations: allocationOperations, targets: targetRows, schedules: scheduleRows)
    }

    func exportReports(report: WorkspaceReportQuery) async throws -> Data {
        let value = try await snapshot(planMonth: Date(), report: report)
        func field(_ value: String) -> String {
            let safe = value.first.map { "=+-@".contains($0) } == true ? "'\(value)" : value
            return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var rows = ["report,period_start,period_end,dimension,name,amount_minor,currency_code"]
        for item in value.spending?.categories ?? [] { rows.append("spending,\(BudgetWorkspaceStore.dateString(report.start)),\(BudgetWorkspaceStore.dateString(report.end)),category,\(field(item.categoryName)),\(item.spendingMinor),\(budget.currencyCode)") }
        for point in value.income?.periods ?? [] {
            rows.append("cash_flow,\(point.periodStart),\(point.periodEnd),metric,income,\(point.incomeMinor),\(budget.currencyCode)")
            rows.append("cash_flow,\(point.periodStart),\(point.periodEnd),metric,spending,\(point.spendingMinor),\(budget.currencyCode)")
        }
        for point in value.netWorth?.points ?? [] { rows.append("net_worth,\(point.asOf),\(point.asOf),metric,net_worth,\(point.netWorthMinor),\(budget.currencyCode)") }
        for point in value.debt?.points ?? [] { rows.append("debt,\(point.asOf),\(point.asOf),metric,debt,\(point.debtMinor),\(budget.currencyCode)") }
        for point in value.planPerformance?.points ?? [] {
            rows.append("plan,\(point.periodStart),\(point.periodEnd),metric,assigned,\(point.assignedMinor),\(budget.currencyCode)")
            rows.append("plan,\(point.periodStart),\(point.periodEnd),metric,spending,\(point.spendingMinor),\(budget.currencyCode)")
            rows.append("plan,\(point.periodStart),\(point.periodEnd),metric,available,\(point.availableMinor),\(budget.currencyCode)")
            rows.append("plan,\(point.periodStart),\(point.periodEnd),metric,unassigned,\(point.readyToAssignMinor),\(budget.currencyCode)")
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    func debtStrategyProjection(_ request: APIDebtStrategyProjectionRequest) async throws -> APIDebtStrategyProjection {
        let selected = demo.visibleAccounts.filter {
            ["credit", "loan"].contains($0.kind.rawValue)
                && (request.accountIDs.isEmpty || request.accountIDs.contains($0.id))
        }
        let missing = selected.compactMap { account -> [String: Any]? in
            let fields = debtTermsValues[account.id].map(missingDebtProjectionFields) ?? ["debt_terms"]
            return fields.isEmpty ? nil : ["account_id": account.id, "missing_projection_fields": fields]
        }
        if !missing.isEmpty {
            return try decode(["currency_code": budget.currencyCode, "status": "incomplete", "strategy": request.strategy, "rollover": request.rollover, "extra_payment_minor": request.extraPaymentMinor, "payoff_order": [], "payment_count": 0, "projected_interest_minor": 0, "projected_total_paid_minor": 0, "projected_total_cost_minor": 0, "accounts": [], "incomplete_accounts": missing])
        }
        let inputs = try selected.compactMap { account -> DebtStrategyInput? in
            guard let terms = debtTermsValues[account.id], let rate = terms.annualRateBasisPoints else { return nil }
            guard let frequency = terms.paymentFrequency.flatMap(DebtPaymentFrequency.init(rawValue:)) else { throw DebtProjectionEngine.ProjectionError.invalidInput }
            let projectionTerms = DebtProjectionTerms(annualRateBasisPoints: Int64(rate), frequency: frequency,
                scheduledPaymentMinor: terms.scheduledPaymentMinor,
                minimumRule: terms.minimumPaymentRule.flatMap(DebtMinimumPaymentRule.init(rawValue:)),
                minimumPaymentMinor: terms.minimumPaymentMinor,
                minimumRateBasisPoints: terms.minimumPaymentRateBasisPoints.map(Int64.init),
                promotionalRateBasisPoints: terms.promotionalRateBasisPoints.map(Int64.init),
                promotionalEndsOn: terms.promotionalEndsOn.map(BudgetWorkspaceStore.parseDate))
            let principal = max(-account.balance, 0)
            let payment = try DebtProjectionEngine.monthlyStrategyPayment(principalMinor: principal,
                firstPaymentOn: BudgetWorkspaceStore.parseDate(request.firstPaymentOn), terms: projectionTerms)
            return .init(debtID: account.id, principalMinor: principal, annualRateBasisPoints: Int64(rate), plannedPaymentMinor: payment, promotionalRateBasisPoints: projectionTerms.promotionalRateBasisPoints, promotionalEndsOn: projectionTerms.promotionalEndsOn)
        }
        let result = try DebtProjectionEngine.projectStrategy(debts: inputs, firstPaymentOn: BudgetWorkspaceStore.parseDate(request.firstPaymentOn), strategy: DebtPayoffStrategy(rawValue: request.strategy) ?? .avalanche, rollover: request.rollover, extraPaymentMinor: request.extraPaymentMinor, customOrder: request.customOrder)
        let rows = result.debts.map { item in
            ["account_id": item.debtID, "payoff_date": item.payoffDate.map(BudgetWorkspaceStore.dateString) ?? NSNull(), "payoff_month": item.payoffMonth ?? NSNull(), "projected_interest_minor": item.projectedInterestMinor, "projected_total_paid_minor": item.projectedTotalPaidMinor] as [String: Any]
        }
        let status = result.status == .paidOff ? "paid_off" : result.status == .nonAmortizing ? "non_amortizing" : "iteration_limit"
        return try decode(["currency_code": budget.currencyCode, "status": status, "strategy": request.strategy, "rollover": request.rollover, "extra_payment_minor": request.extraPaymentMinor, "payoff_order": result.payoffOrder, "debt_free_date": result.debtFreeDate.map(BudgetWorkspaceStore.dateString) ?? NSNull(), "payment_count": result.paymentCount, "projected_interest_minor": result.projectedInterestMinor, "projected_total_paid_minor": result.projectedTotalPaidMinor, "projected_total_cost_minor": result.projectedTotalCostMinor, "accounts": rows, "incomplete_accounts": []])
    }

    private func missingDebtProjectionFields(_ terms: APIAccountDebtTermsUpsert) -> [String] {
        var fields: [String] = []
        if terms.annualRateBasisPoints == nil { fields.append("annual_rate_basis_points") }
        if terms.rateType == nil { fields.append("rate_type") }
        if terms.paymentFrequency == nil { fields.append("payment_frequency") }
        if terms.dueDay == nil { fields.append("due_day") }
        if terms.termsType == "credit_card" {
            if terms.minimumPaymentRule == nil { fields.append("minimum_payment_rule") }
            if ["fixed", "greater_of"].contains(terms.minimumPaymentRule ?? "") && terms.minimumPaymentMinor == nil { fields.append("minimum_payment_minor") }
            if ["percentage", "greater_of"].contains(terms.minimumPaymentRule ?? "") && terms.minimumPaymentRateBasisPoints == nil { fields.append("minimum_payment_rate_basis_points") }
        } else if terms.scheduledPaymentMinor == nil { fields.append("scheduled_payment_minor") }
        return fields
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
}

extension DemoWorkspaceDataSource: WorkspaceCommandRepository {
    func householdInvitations() async throws -> [APIInvitationSummary] { [] }
    func createHouseholdInvitation(_ value: APIInvitationCreate) async throws -> APIInvitationSecret { try decode(["invitation_token": "DEMO-INVITATION-CODE", "email": value.email, "role": value.role, "expires_at": "2026-09-23T12:00:00Z"]) }
    func resendHouseholdInvitation(id: String) async throws -> APIInvitationSecret { try decode(["invitation_token": "DEMO-INVITATION-CODE", "email": "member@example.test", "role": "adult", "expires_at": "2026-09-23T12:00:00Z"]) }
    func cancelHouseholdInvitation(id: String) async throws {}
    func removeHouseholdMember(userID: String) async throws {}
    func householdAccessEvents() async throws -> [APIHouseholdAccessEvent] { [] }
    func cancelRequest(id: String, version: Int, note: String) async throws {}
    func reviseRequest(id: String, version: Int, value: APIFinancialRequestCreate) async throws {}
    func createAllowance(_ value: APIAllowancePlanCreate) async throws {}
    func setAllowanceActive(id: String, active: Bool) async throws {}
    func issueAllowance(id: String, issueDate: String, expectedVersion: Int) async throws {}
    func allowanceIssuances(id: String) async throws -> [APIAllowanceIssuance] { [] }
    func accessProfile(userID: String) async throws -> APIAccessProfile {
        if let profile = accessProfiles[userID] { return profile }
        return try decode(["budget_id": budget.id, "user_id": userID, "capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances"], "restrict_accounts": false, "account_ids": [], "restrict_categories": false, "category_ids": [], "grant_permission": "view", "is_custom": false, "version": 0, "updated_by_user_id": NSNull(), "updated_by_display_name": NSNull(), "updated_at": NSNull()])
    }

    func updateAccessProfile(userID: String, value: APIAccessProfileUpsert) async throws -> APIAccessProfile {
        let current = try await accessProfile(userID: userID)
        guard value.expectedVersion == nil || value.expectedVersion == current.version else { throw APIClientError.server(status: 409, message: "Access changed elsewhere. Reload and try again.") }
        let profile: APIAccessProfile = try decode(["budget_id": budget.id, "user_id": userID, "capabilities": value.capabilities, "restrict_accounts": value.restrictAccounts, "account_ids": value.accountIDs, "restrict_categories": value.restrictCategories, "category_ids": value.categoryIDs, "grant_permission": "custom", "is_custom": true, "version": current.version + 1, "updated_by_user_id": "demo-owner", "updated_by_display_name": "Alex Rivera", "updated_at": "2026-09-16T12:00:00Z"])
        accessProfiles[userID] = profile
        return profile
    }
    func browseTransactions(query: APITransactionQuery) async throws -> APITransactionPage {
        let calendar = Calendar.current
        let report = WorkspaceReportQuery(start: calendar.date(byAdding: .year, value: -100, to: Date())!, end: calendar.date(byAdding: .year, value: 100, to: Date())!, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
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
        case "interest_charge": return item.transferID == nil && (item.financialClassification == "interest_charge" || item.splits.contains { $0.financialClassification == "interest_charge" })
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
        let splits = amounts.count > 1 ? amounts.keys.sorted().map { TransactionSplitOperation(categoryID: $0, amountMinor: amounts[$0]!, memo: "", financialClassification: source.splitFinancialClassifications[$0]) } : []
        let operation = RecordTransactionOperation(accountID: source.accountID, categoryID: singleCategory, amountMinor: source.amount, occurredOn: occurredOn, payeeName: source.payee, payeeID: demo.payees.first(where: { $0.name == source.payee })?.id, memo: source.memo, financialClassification: source.financialClassification, isCleared: false, splits: splits, flag: source.flag, tags: source.tags, attachmentMetadata: [])
        guard demo.recordCanonicalTransaction(operation) else { throw workspaceRepositoryError(demo.errorMessage) }
    }
    func voidTransaction(id: String, reason: String) async throws {
        guard let source = demo.transactions.first(where: { $0.id == id }), source.status == "posted", source.transferID == nil, !source.reconciled else { throw workspaceRepositoryError("Only an unreconciled posted transaction can be voided") }
        let amounts = demo.canonicalCategoryAmounts(for: source)
        let splits = amounts.count > 1 ? amounts.keys.sorted().map { TransactionSplitOperation(categoryID: $0, amountMinor: -amounts[$0]!, memo: "", financialClassification: source.splitFinancialClassifications[$0]) } : []
        let operation = RecordTransactionOperation(accountID: source.accountID, categoryID: amounts.count == 1 ? amounts.keys.first : nil, amountMinor: -source.amount, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: "Reversal: \(source.payee)", memo: reason.isEmpty ? "Void reversal." : "Void reversal. \(reason)", financialClassification: source.financialClassification, isCleared: false, splits: splits, flag: source.flag, tags: source.tags, attachmentMetadata: [])
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
        demo.schedules.append(.init(id: UUID().uuidString, accountID: source.accountID, destinationAccountID: nil, categoryID: source.categoryIDs.first, name: source.payee, amount: source.amount, nextDate: operation.nextDate, recurrenceUnit: operation.recurrenceUnit, intervalCount: operation.intervalCount, memo: source.memo, financialClassification: source.financialClassification, isActive: true))
    }
    func transactionAttachments(id: String) async throws -> [APITransactionAttachment] {
        guard let transaction = demo.transactions.first(where: { $0.id == id }) else { throw workspaceRepositoryError("Transaction not found") }
        guard let name = transaction.attachmentName else { return [] }
        let data = attachmentData[id] ?? Data()
        let contentType = name.lowercased().hasSuffix(".png") ? "image/png" : "application/pdf"
        return [try JSONDecoder().decode(APITransactionAttachment.self, from: JSONSerialization.data(withJSONObject: ["id": "demo-attachment-\(id)", "transaction_id": id, "filename": name, "content_type": contentType, "byte_count": data.count, "sha256": "demo", "created_at": "2026-09-14T00:00:00Z", "detached_at": NSNull()]))]
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
    func accountDebtTerms(accountID: String) async throws -> APIAccountDebtTerms? {
        guard let value = debtTermsValues[accountID] else { return nil }
        return try decode([
            "account_id": accountID, "budget_id": budget.id, "terms_type": value.termsType,
            "annual_rate_basis_points": value.annualRateBasisPoints ?? NSNull(), "rate_type": value.rateType ?? NSNull(),
            "payment_frequency": value.paymentFrequency ?? NSNull(), "scheduled_payment_minor": value.scheduledPaymentMinor ?? NSNull(),
            "minimum_payment_rule": value.minimumPaymentRule ?? NSNull(), "minimum_payment_minor": value.minimumPaymentMinor ?? NSNull(),
            "minimum_payment_rate_basis_points": value.minimumPaymentRateBasisPoints ?? NSNull(), "due_day": value.dueDay ?? NSNull(),
            "statement_day": value.statementDay ?? NSNull(), "original_principal_minor": value.originalPrincipalMinor ?? NSNull(),
            "original_term_months": value.originalTermMonths ?? NSNull(), "remaining_term_months": value.remainingTermMonths ?? NSNull(),
            "promotional_rate_basis_points": value.promotionalRateBasisPoints ?? NSNull(), "promotional_ends_on": value.promotionalEndsOn ?? NSNull(),
            "projection_ready": missingDebtProjectionFields(value).isEmpty, "missing_projection_fields": missingDebtProjectionFields(value), "updated_at": "2026-09-16T12:00:00Z",
        ] as [String: Any])
    }
    func updateAccountDebtTerms(accountID: String, value: APIAccountDebtTermsUpsert) async throws -> APIAccountDebtTerms {
        debtTermsValues[accountID] = value
        guard let result = try await accountDebtTerms(accountID: accountID) else {
            throw workspaceRepositoryError("Debt terms were not saved.")
        }
        return result
    }
    func deleteAccountDebtTerms(accountID: String) async throws { debtTermsValues.removeValue(forKey: accountID) }
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
    func setCategoryFavorite(id: String, isFavorite: Bool, sortOrder: Int) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Category not found.") }
        demo.categories[index].pinned = isFavorite
    }
    func saveTarget(categoryID: String, value: APICategoryTargetUpsert) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == categoryID }) else { throw workspaceRepositoryError("Category not found.") }
        demo.categories[index].target = value.targetAmountMinor; demo.categories[index].targetDate = value.targetDate; demo.categories[index].targetType = value.targetType; demo.categories[index].targetRecurrenceMonths = value.recurrenceMonths; demo.categories[index].targetMinimumContribution = value.minimumContributionMinor; demo.categories[index].targetPriority = value.priority; demo.categories[index].targetIsActive = value.isActive
    }
    func deleteTarget(categoryID: String) async throws {
        guard let index = demo.categories.firstIndex(where: { $0.id == categoryID }) else { throw workspaceRepositoryError("Category not found.") }
        demo.categories[index].target = nil; demo.categories[index].targetDate = nil; demo.categories[index].targetType = "savings_balance"; demo.categories[index].targetRecurrenceMonths = nil; demo.categories[index].targetMinimumContribution = 0; demo.categories[index].targetPriority = 50; demo.categories[index].targetIsActive = true
    }
    func createSchedule(_ operation: ScheduleOperation) async throws { demo.schedules.append(.init(id: UUID().uuidString, accountID: operation.accountID, destinationAccountID: operation.destinationAccountID, categoryID: operation.categoryID, name: operation.name, amount: operation.amountMinor, nextDate: operation.nextDate, recurrenceUnit: operation.recurrenceUnit, intervalCount: operation.intervalCount, memo: operation.memo, financialClassification: operation.financialClassification, isActive: operation.isActive)) }
    func updateSchedule(id: String, operation: ScheduleOperation) async throws {
        guard let index = demo.schedules.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Schedule not found.") }
        demo.schedules[index].accountID = operation.accountID; demo.schedules[index].destinationAccountID = operation.destinationAccountID; demo.schedules[index].categoryID = operation.categoryID; demo.schedules[index].name = operation.name; demo.schedules[index].amount = operation.amountMinor; demo.schedules[index].nextDate = operation.nextDate; demo.schedules[index].recurrenceUnit = operation.recurrenceUnit; demo.schedules[index].intervalCount = operation.intervalCount; demo.schedules[index].memo = operation.memo; demo.schedules[index].financialClassification = operation.financialClassification; demo.schedules[index].isActive = operation.isActive
    }
    func deleteSchedule(id: String) async throws { demo.schedules.removeAll { $0.id == id } }
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation {
        guard let index = demo.schedules.firstIndex(where: { $0.id == id }) else { throw workspaceRepositoryError("Schedule not found.") }
        let item = demo.schedules[index]; guard item.isActive else { throw workspaceRepositoryError("Scheduled transaction is inactive") }
        let due = BudgetWorkspaceStore.parseDate(item.nextDate); guard Calendar.current.startOfDay(for: due) <= Calendar.current.startOfDay(for: Date()) else { throw workspaceRepositoryError("This scheduled transaction is not due yet") }
        let before = Set(demo.transactions.map(\.id))
        if let destination = item.destinationAccountID { guard demo.transfer(amount: item.amount, from: item.accountID, to: destination, memo: item.memo, cleared: false, date: due) else { throw workspaceRepositoryError(demo.errorMessage) } }
        else {
            let operation = RecordTransactionOperation(accountID: item.accountID, categoryID: item.categoryID, amountMinor: item.amount, occurredOn: item.nextDate, payeeName: item.name, memo: item.memo, financialClassification: item.financialClassification, isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])
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

    func householdInvitations() async throws -> [APIInvitationSummary] { try await credentials.prepare(); return try await client.householdInvitations(householdID: budget.householdID, token: token) }
    func createHouseholdInvitation(_ value: APIInvitationCreate) async throws -> APIInvitationSecret { try await credentials.prepare(); return try await client.createHouseholdInvitation(householdID: budget.householdID, value: value, token: token) }
    func resendHouseholdInvitation(id: String) async throws -> APIInvitationSecret { try await credentials.prepare(); return try await client.resendHouseholdInvitation(householdID: budget.householdID, invitationID: id, token: token) }
    func cancelHouseholdInvitation(id: String) async throws { try await credentials.prepare(); try await client.cancelHouseholdInvitation(householdID: budget.householdID, invitationID: id, token: token) }
    func removeHouseholdMember(userID: String) async throws { try await credentials.prepare(); try await client.removeHouseholdMember(householdID: budget.householdID, userID: userID, token: token) }
    func householdAccessEvents() async throws -> [APIHouseholdAccessEvent] { try await credentials.prepare(); return try await client.householdAccessEvents(householdID: budget.householdID, token: token) }

    func accessProfile(userID: String) async throws -> APIAccessProfile { try await credentials.prepare(); return try await client.accessProfile(budgetID: budget.id, userID: userID, token: token) }
    func updateAccessProfile(userID: String, value: APIAccessProfileUpsert) async throws -> APIAccessProfile { try await credentials.prepare(); return try await client.updateAccessProfile(budgetID: budget.id, userID: userID, profile: value, token: token) }
    func cancelRequest(id: String, version: Int, note: String) async throws { try await credentials.prepare(); _ = try await client.cancelFinancialRequest(budgetID: budget.id, requestID: id, expectedVersion: version, note: note, token: token) }
    func reviseRequest(id: String, version: Int, value: APIFinancialRequestCreate) async throws { try await credentials.prepare(); _ = try await client.reviseFinancialRequest(budgetID: budget.id, requestID: id, value: value, expectedVersion: version, token: token) }
    func createAllowance(_ value: APIAllowancePlanCreate) async throws { try await credentials.prepare(); _ = try await client.createAllowancePlan(budgetID: budget.id, value: value, token: token) }
    func setAllowanceActive(id: String, active: Bool) async throws { try await credentials.prepare(); _ = try await client.setAllowancePlanActive(budgetID: budget.id, planID: id, isActive: active, token: token) }
    func issueAllowance(id: String, issueDate: String, expectedVersion: Int) async throws { try await credentials.prepare(); _ = try await client.issueAllowance(budgetID: budget.id, planID: id, issueDate: issueDate, expectedAllocationVersion: expectedVersion, token: token) }
    func allowanceIssuances(id: String) async throws -> [APIAllowanceIssuance] { try await credentials.prepare(); return try await client.allowanceIssuances(budgetID: budget.id, planID: id, token: token) }

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
    func accountDebtTerms(accountID: String) async throws -> APIAccountDebtTerms? { try await credentials.prepare(); return try await client.accountDebtTerms(budgetID: budget.id, accountID: accountID, token: token) }
    func updateAccountDebtTerms(accountID: String, value: APIAccountDebtTermsUpsert) async throws -> APIAccountDebtTerms { try await credentials.prepare(); return try await client.updateAccountDebtTerms(budgetID: budget.id, accountID: accountID, terms: value, token: token) }
    func deleteAccountDebtTerms(accountID: String) async throws { try await credentials.prepare(); try await client.deleteAccountDebtTerms(budgetID: budget.id, accountID: accountID, token: token) }
    func createRequest(_ value: APIFinancialRequestCreate) async throws { try await credentials.prepare(); _ = try await client.createFinancialRequest(budgetID: budget.id, request: value, token: token) }
    func updateCategory(id: String, value: APICategoryUpdate, groupName: String?, existingDelegatedUserID: String?, delegatedUserID: String?) async throws { try await credentials.prepare(); _ = try await client.updateCategory(budgetID: budget.id, categoryID: id, category: value, token: token); if existingDelegatedUserID != delegatedUserID { _ = try await client.updateCategoryDelegation(budgetID: budget.id, categoryID: id, delegatedUserID: delegatedUserID, token: token) } }
    func updateGroup(id: String, currentName: String?, value: APICategoryGroupUpdate) async throws { try await credentials.prepare(); _ = try await client.updateCategoryGroup(budgetID: budget.id, groupID: id, group: value, token: token) }
    func deleteGroup(id: String, currentName: String?) async throws { try await credentials.prepare(); try await client.deleteCategoryGroup(budgetID: budget.id, groupID: id, token: token) }
    func deleteCategory(id: String) async throws { try await credentials.prepare(); try await client.deleteCategory(budgetID: budget.id, categoryID: id, token: token) }
    func setCategoryFavorite(id: String, isFavorite: Bool, sortOrder: Int) async throws { try await credentials.prepare(); if isFavorite { _ = try await client.favoriteCategory(budgetID: budget.id, categoryID: id, sortOrder: sortOrder, token: token) } else { try await client.unfavoriteCategory(budgetID: budget.id, categoryID: id, token: token) } }
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

    func reports(planMonth: Date, query report: WorkspaceReportQuery, kinds: Set<WorkspaceReportKind>) async throws -> WorkspaceReports {
        guard !kinds.isEmpty, budget.can("view_reports") else { return WorkspaceReports() }
        try await credentials.prepare()
        let client = try credentials.client()
        let token = credentials.token
        let start = BudgetWorkspaceStore.dateString(report.start), end = BudgetWorkspaceStore.dateString(report.end)
        let cleared = report.cleared == "all" || report.cleared == "reconciled" ? nil : report.cleared == "cleared"
        let reconciled = report.cleared == "reconciled" ? true : nil
        async let loadedSpending: APISpendingReport? = kinds.contains(.spending) ? client.spendingReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], categoryIDs: report.categoryID.isEmpty ? [] : [report.categoryID], categoryGroups: report.categoryGroup.isEmpty ? [] : [report.categoryGroup], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], transactionType: report.transactionType.isEmpty ? nil : report.transactionType, cleared: cleared, reconciled: reconciled, flags: report.flag.isEmpty ? [] : [report.flag], tags: report.tag.isEmpty ? [] : [report.tag], includeTracking: report.includeTracking, token: token) : nil
        async let loadedSpendingTrends: APISpendingTrendsReport? = kinds.contains(.spendingTrends) ? client.spendingTrendsReport(budgetID: budget.id, startDate: start, endDate: end, dimension: report.spendingTrendDimension, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], categoryIDs: report.categoryID.isEmpty ? [] : [report.categoryID], categoryGroups: report.categoryGroup.isEmpty ? [] : [report.categoryGroup], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], transactionType: report.transactionType.isEmpty ? nil : report.transactionType, cleared: cleared, reconciled: reconciled, flags: report.flag.isEmpty ? [] : [report.flag], tags: report.tag.isEmpty ? [] : [report.tag], includeTracking: report.includeTracking, token: token) : nil
        async let loadedIncome: APIIncomeSpendingReport? = kinds.contains(.income) ? client.incomeSpendingReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], cleared: cleared, reconciled: reconciled, flags: report.flag.isEmpty ? [] : [report.flag], tags: report.tag.isEmpty ? [] : [report.tag], includeTracking: report.includeTracking, token: token) : nil
        async let loadedNetWorth: APINetWorthReport? = kinds.contains(.netWorth) && budget.can("view_account_balances") ? client.netWorthReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], includeTracking: report.includeTracking, token: token) : nil
        async let loadedDebt: APIDebtReport? = kinds.contains(.debt) && budget.can("view_account_balances") ? client.debtReport(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], token: token) : nil
        async let loadedPlanPerformance: APIPlanPerformanceReport? = kinds.contains(.planPerformance) ? client.planPerformanceReport(budgetID: budget.id, startDate: start, endDate: end, token: token) : nil
        async let loadedResilience: APIResilienceReport? = kinds.contains(.resilience) && budget.can("view_account_balances") ? client.resilienceReport(budgetID: budget.id, token: token) : nil
        async let loadedSummary: APIInsightsSummary? = kinds.contains(.summary) ? client.insightsSummary(budgetID: budget.id, startDate: start, endDate: end, accountIDs: report.accountID.isEmpty ? [] : [report.accountID], memberIDs: report.memberID.isEmpty ? [] : [report.memberID], payees: report.payee.isEmpty ? [] : [report.payee], cleared: cleared, reconciled: reconciled, flags: report.flag.isEmpty ? [] : [report.flag], tags: report.tag.isEmpty ? [] : [report.tag], includeTracking: report.includeTracking, token: token) : nil
        return try await WorkspaceReports(spending: loadedSpending, spendingTrends: loadedSpendingTrends,
            income: loadedIncome, netWorth: loadedNetWorth, debt: loadedDebt,
            planPerformance: loadedPlanPerformance, resilience: loadedResilience, summary: loadedSummary)
    }

    func snapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot {
        try await loadSnapshot(planMonth: planMonth, report: report, kinds: Set(WorkspaceReportKind.allCases))
    }

    func coreSnapshot(planMonth: Date, report: WorkspaceReportQuery) async throws -> WorkspaceSnapshot {
        try await loadSnapshot(planMonth: planMonth, report: report, kinds: [])
    }

    private func loadSnapshot(planMonth: Date, report: WorkspaceReportQuery, kinds: Set<WorkspaceReportKind>) async throws -> WorkspaceSnapshot {
        try await credentials.prepare()
        let client = try credentials.client()
        let month = BudgetWorkspaceStore.dateString(planMonth).prefix(7) + "-01"
        async let loadedAccounts = client.accounts(budgetID: budget.id, token: token)
        async let loadedTransactions = client.transactions(budgetID: budget.id, token: token)
        async let loadedCategories = client.categories(budgetID: budget.id, token: token)
        async let loadedGroups = client.categoryGroups(budgetID: budget.id, token: token)
        async let loadedSummary = client.monthSummary(budgetID: budget.id, month: String(month), token: token)
        async let loadedReports = self.reports(planMonth: planMonth, query: report, kinds: kinds)
        let (accounts, transactions, categories, groups, summary, reports) = try await
            (loadedAccounts, loadedTransactions, loadedCategories, loadedGroups, loadedSummary, loadedReports)
        let spending = reports.spending, spendingTrends = reports.spendingTrends, income = reports.income
        let netWorth = reports.netWorth, debt = reports.debt, planPerformance = reports.planPerformance, resilience = reports.resilience
        let allocationOperations = budget.can("view_allocation_history") ? (try? await client.allocationOperations(budgetID: budget.id, token: token)) ?? [] : []
        let schedules = budget.can("view_transactions") ? try await client.scheduledTransactions(budgetID: budget.id, includeInactive: true, token: token) : []
        let targets = await withTaskGroup(of: APICategoryTarget?.self) { group in for category in categories { group.addTask { try? await client.categoryTarget(budgetID: self.budget.id, categoryID: category.id, token: self.token) } }; var values: [APICategoryTarget] = []; for await target in group { if let target { values.append(target) } }; return values }
        let balances = await withTaskGroup(of: APIAccountBalance?.self) { group in for account in accounts { group.addTask { try? await client.accountBalance(budgetID: self.budget.id, accountID: account.id, token: self.token) } }; var values: [APIAccountBalance] = []; for await value in group { if let value { values.append(value) } }; return values }
        let requests = (budget.can("request_money") || budget.can("approve_request")) ? (try? await client.financialRequests(budgetID: budget.id, token: token)) ?? [] : []
        let allowances = (try? await client.allowancePlans(budgetID: budget.id, includeInactive: budget.can("manage_allowances"), token: token)) ?? []
        let delegated = try? await client.delegatedBudget(budgetID: budget.id, token: token)
        let forecast: APIForecast? = if budget.can("view_account_balances") { try? await client.forecast(budgetID: budget.id, through: BudgetWorkspaceStore.dateString(Calendar.current.date(byAdding: .day, value: 90, to: Date())!), token: token) } else { nil }
        let members = budget.can("manage_allowances") ? (try? await client.householdMembers(householdID: budget.householdID, token: token)) ?? [] : []
        let delegatedBudgets = budget.can("manage_allowances") ? (try? await client.delegatedBudgets(budgetID: budget.id, token: token)) ?? [] : []
        return WorkspaceSnapshot(accounts: accounts, accountBalances: Dictionary(uniqueKeysWithValues: balances.map { ($0.accountID, $0) }), categories: categories, groups: groups, transactions: transactions, summary: summary, payees: [], requests: requests, allowances: allowances, spending: spending, spendingTrends: spendingTrends, income: income, netWorth: netWorth, debt: debt, planPerformance: planPerformance, resilience: resilience, delegated: delegated, forecast: forecast, members: members, delegatedBudgets: delegatedBudgets, allocationOperations: allocationOperations, targets: targets, schedules: schedules)
    }

    func exportReports(report: WorkspaceReportQuery) async throws -> Data {
        try await credentials.prepare()
        return try await credentials.client().reportExportCSV(
            budgetID: budget.id, startDate: BudgetWorkspaceStore.dateString(report.start),
            endDate: BudgetWorkspaceStore.dateString(report.end), token: token
        )
    }

    func debtStrategyProjection(_ request: APIDebtStrategyProjectionRequest) async throws -> APIDebtStrategyProjection {
        try await credentials.prepare()
        return try await credentials.client().debtStrategyProjection(budgetID: budget.id, request: request, token: token)
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
    @Published var spendingTrendsReport: APISpendingTrendsReport?
    @Published var incomeReport: APIIncomeSpendingReport?
    @Published var netWorthReport: APINetWorthReport?
    @Published var debtReport: APIDebtReport?
    @Published var planPerformanceReport: APIPlanPerformanceReport?
    @Published var resilienceReport: APIResilienceReport?
    @Published var insightsSummary: APIInsightsSummary?
    @Published private(set) var reportRevision = 0
    @Published private(set) var loadedReportKinds: Set<WorkspaceReportKind> = []
    @Published private(set) var reportErrors: [WorkspaceReportKind: String] = [:]
    private var loadedReportContext: WorkspaceReportContext?
    private var pendingReports: [WorkspaceReportKind: Task<WorkspaceReports, Error>] = [:]
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
    @Published var reportFlag = ""
    @Published var reportTag = ""
    @Published var spendingTrendDimension = "category"
    @Published var includeTrackingAccounts = false
    @Published var planMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hideAmounts = false {
        didSet {
            guard hideAmounts != oldValue, let privacyPreferenceKey else { return }
            UserDefaults.standard.set(hideAmounts, forKey: privacyPreferenceKey)
            // Privacy changes must be durable before the app can enter the background or be
            // terminated from the switcher immediately after the toggle changes.
            UserDefaults.standard.synchronize()
        }
    }
    @Published private(set) var onboardingStep = 0
    @Published private(set) var onboardingDismissed = false
    @Published private(set) var onboardingCompleted = false
    private var dataSource: WorkspaceDataSource?
    private var commandRepository: WorkspaceCommandRepository?
    private var applicationServices: BudgetApplicationServices?
    private var transactionBrowseTask: Task<APITransactionPage, Error>?
    private var transactionBrowseQuery: APITransactionQuery?
    private var transactionBrowseOperationID: UUID?
    private var privacyPreferenceKey: String?
    private var onboardingPreferencePrefix: String?

    init(budget: APIBudget) { self.budget = budget; dataSource = nil; commandRepository = nil; applicationServices = nil }
    private init(dataSource: DemoWorkspaceDataSource) {
        self.budget = dataSource.budget
        self.dataSource = dataSource
        commandRepository = dataSource
        applicationServices = BudgetApplicationServices(repository: dataSource)
        configurePrivacy(userID: "deterministic-demo-user")
    }
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
                let query = WorkspaceReportQuery(start: range.0, end: range.1, accountID: reportAccountID, categoryID: reportCategoryID, categoryGroup: reportCategoryGroup, payee: reportPayee, memberID: reportMemberID, transactionType: reportTransactionType, cleared: reportCleared, flag: reportFlag, tag: reportTag, spendingTrendDimension: spendingTrendDimension, includeTracking: includeTrackingAccounts)
                let value = try await dataSource.coreSnapshot(planMonth: planMonth, report: query)
                accounts = value.accounts; accountBalances = value.accountBalances; categories = value.categories; groups = value.groups; transactions = value.transactions; payees = value.payees
                summary = value.summary; requests = value.requests; allowances = value.allowances
                // Preserve report-backed destination identity while new authoritative reports load.
                // Readiness is invalidated below; report screens never display these as current.
                delegatedBudget = value.delegated; forecast = value.forecast
                householdMembers = value.members; delegatedBudgets = value.delegatedBudgets; allocationOperations = value.allocationOperations; errorMessage = nil
                targets = Dictionary(uniqueKeysWithValues: value.targets.map { ($0.categoryID, $0) })
                scheduledTransactions = value.schedules
                reportRevision += 1
                return
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async { await loadSnapshot() }

    func fetchReports(query: WorkspaceReportQuery, kinds: Set<WorkspaceReportKind>) async throws -> WorkspaceReports {
        guard let dataSource else { throw workspaceRepositoryError("Reports are unavailable.") }
        return try await dataSource.reports(planMonth: planMonth, query: query, kinds: kinds)
    }

    var reportContext: WorkspaceReportContext {
        let range = reportRange()
        let query = WorkspaceReportQuery(start: range.0, end: range.1, accountID: reportAccountID, categoryID: reportCategoryID, categoryGroup: reportCategoryGroup, payee: reportPayee, memberID: reportMemberID, transactionType: reportTransactionType, cleared: reportCleared, flag: reportFlag, tag: reportTag, spendingTrendDimension: spendingTrendDimension, includeTracking: includeTrackingAccounts)
        return WorkspaceReportContext(query: query, planMonth: planMonth, revision: reportRevision, credentialRevision: liveCredentialRevision)
    }

    func reportsReady(_ kinds: Set<WorkspaceReportKind>) -> Bool {
        loadedReportContext == reportContext && kinds.isSubset(of: loadedReportKinds)
    }

    func resetReportSelection() {
        reportPeriod = "30d"
        reportAccountID = ""; reportCategoryID = ""; reportCategoryGroup = ""
        reportPayee = ""; reportMemberID = ""; reportTransactionType = ""
        reportCleared = "all"; reportFlag = ""; reportTag = ""; includeTrackingAccounts = false
        let range = reportRange()
        customReportStart = range.0; customReportEnd = range.1
    }

    func loadReports(_ kinds: Set<WorkspaceReportKind>, retry: Bool = false) async {
        guard let dataSource else { return }
        let context = reportContext
        if loadedReportContext != context {
            for task in pendingReports.values { task.cancel() }
            pendingReports = [:]; loadedReportKinds = []; reportErrors = [:]
            loadedReportContext = context
        }
        for kind in kinds {
            guard !loadedReportKinds.contains(kind) else { continue }
            if !retry, reportErrors[kind] != nil { continue }
            reportErrors[kind] = nil
            let task: Task<WorkspaceReports, Error>
            if let existing = pendingReports[kind] { task = existing }
            else {
                task = Task { try await dataSource.reports(planMonth: context.planMonth, query: context.query, kinds: [kind]) }
                pendingReports[kind] = task
            }
            do {
                let value = try await task.value
                guard context == reportContext, loadedReportContext == context else { return }
                switch kind {
                case .summary: insightsSummary = value.summary
                case .spending: spendingReport = value.spending
                case .spendingTrends: spendingTrendsReport = value.spendingTrends
                case .income: incomeReport = value.income
                case .netWorth: netWorthReport = value.netWorth
                case .debt: debtReport = value.debt
                case .planPerformance: planPerformanceReport = value.planPerformance
                case .resilience: resilienceReport = value.resilience
                }
                loadedReportKinds.insert(kind)
            } catch {
                guard context == reportContext, loadedReportContext == context else { return }
                reportErrors[kind] = error.localizedDescription
            }
            pendingReports[kind] = nil
        }
    }

    func exportReports() async throws -> URL {
        guard budget.can("export_data"), let dataSource else {
            throw APIClientError.server(status: 403, message: "Report export is not available for this budget.")
        }
        let range = reportRange()
        let query = WorkspaceReportQuery(start: range.0, end: range.1, accountID: reportAccountID, categoryID: reportCategoryID, categoryGroup: reportCategoryGroup, payee: reportPayee, memberID: reportMemberID, transactionType: reportTransactionType, cleared: reportCleared, flag: reportFlag, tag: reportTag, spendingTrendDimension: spendingTrendDimension, includeTracking: includeTrackingAccounts)
        let data = try await dataSource.exportReports(report: query)
        let name = "budget-reports-\(Self.dateString(range.0))-\(Self.dateString(range.1)).csv"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func debtStrategyProjection(_ request: APIDebtStrategyProjectionRequest) async throws -> APIDebtStrategyProjection {
        guard let dataSource else { throw workspaceRepositoryError("Debt payoff scenarios are unavailable.") }
        return try await dataSource.debtStrategyProjection(request)
    }

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

    func accountDebtTerms(accountID: String) async throws -> APIAccountDebtTerms? {
        try await commands().accountDebtTerms(accountID: accountID)
    }

    func updateAccountDebtTerms(accountID: String, value: APIAccountDebtTermsUpsert) async throws -> APIAccountDebtTerms {
        try await commands().updateAccountDebtTerms(accountID: accountID, value: value)
    }

    func deleteAccountDebtTerms(accountID: String) async throws {
        try await commands().deleteAccountDebtTerms(accountID: accountID)
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
    func setCategoryFavorite(id: String, isFavorite: Bool) async throws {
        let nextOrder = (categories.compactMap(\.favoriteSortOrder).max() ?? -1) + 1
        try await commands().setCategoryFavorite(id: id, isFavorite: isFavorite, sortOrder: nextOrder)
        await refresh()
    }

    func configurePrivacy(userID: String?) {
        let identity = userID ?? "deterministic-demo-user"
        let key = "budget.privacy.hide-amounts.\(identity).\(budget.id)"
        guard privacyPreferenceKey != key else { return }
        privacyPreferenceKey = key
        hideAmounts = UserDefaults.standard.bool(forKey: key)
    }

    func configureOnboarding(userID: String?) {
        let identity = userID ?? "anonymous"
        let prefix = "budget.guided-onboarding.\(identity).\(budget.id)"
        guard prefix != onboardingPreferencePrefix else { return }
        onboardingPreferencePrefix = prefix
        onboardingStep = UserDefaults.standard.integer(forKey: "\(prefix).step")
        onboardingDismissed = UserDefaults.standard.bool(forKey: "\(prefix).dismissed")
        onboardingCompleted = UserDefaults.standard.bool(forKey: "\(prefix).completed")
    }

    func saveOnboarding(step: Int? = nil, dismissed: Bool? = nil, completed: Bool? = nil) {
        guard let prefix = onboardingPreferencePrefix else { return }
        if let step { onboardingStep = step; UserDefaults.standard.set(step, forKey: "\(prefix).step") }
        if let dismissed { onboardingDismissed = dismissed; UserDefaults.standard.set(dismissed, forKey: "\(prefix).dismissed") }
        if let completed { onboardingCompleted = completed; UserDefaults.standard.set(completed, forKey: "\(prefix).completed") }
        UserDefaults.standard.synchronize()
    }

    func restartOnboarding() { saveOnboarding(step: 0, dismissed: false, completed: false) }
    func resumeOnboarding() { saveOnboarding(dismissed: false, completed: false) }

    var isGenuinelyEmptyForOnboarding: Bool {
        budget.effectivePermission == .owner && accounts.isEmpty && categories.isEmpty && transactions.isEmpty
    }

    func setHideAmounts(_ hidden: Bool) {
        hideAmounts = hidden
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

    func accessProfile(userID: String) async throws -> APIAccessProfile { try await commands().accessProfile(userID: userID) }

    func cancelRequest(id: String, version: Int, note: String) async throws { try await commands().cancelRequest(id: id, version: version, note: note); await refresh() }
    func reviseRequest(id: String, version: Int, value: APIFinancialRequestCreate) async throws { try await commands().reviseRequest(id: id, version: version, value: value); await refresh() }
    func createAllowance(_ value: APIAllowancePlanCreate) async throws { try await commands().createAllowance(value); await refresh() }
    func setAllowanceActive(id: String, active: Bool) async throws { try await commands().setAllowanceActive(id: id, active: active); await refresh() }
    func issueAllowance(id: String, issueDate: String, expectedVersion: Int) async throws { try await commands().issueAllowance(id: id, issueDate: issueDate, expectedVersion: expectedVersion); await refresh() }
    func allowanceIssuances(id: String) async throws -> [APIAllowanceIssuance] { try await commands().allowanceIssuances(id: id) }

    func householdInvitations() async throws -> [APIInvitationSummary] { try await commands().householdInvitations() }
    func createHouseholdInvitation(_ value: APIInvitationCreate) async throws -> APIInvitationSecret { try await commands().createHouseholdInvitation(value) }
    func resendHouseholdInvitation(id: String) async throws -> APIInvitationSecret { try await commands().resendHouseholdInvitation(id: id) }
    func cancelHouseholdInvitation(id: String) async throws { try await commands().cancelHouseholdInvitation(id: id) }
    func removeHouseholdMember(userID: String) async throws { try await commands().removeHouseholdMember(userID: userID); await refresh() }
    func householdAccessEvents() async throws -> [APIHouseholdAccessEvent] { try await commands().householdAccessEvents() }

    func updateAccessProfile(userID: String, value: APIAccessProfileUpsert) async throws -> APIAccessProfile {
        try await commands().updateAccessProfile(userID: userID, value: value)
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
        guard !hideAmounts else { return "••••" }
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: BudgetWorkspaceStore
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @State private var didEvaluateOnboarding = false
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
        .overlay {
            if store.hideAmounts && scenePhase != .active {
                PrivacyShieldView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.hideAmounts && scenePhase == .active {
                Label("Amounts hidden", systemImage: "eye.slash.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 12)
                    .accessibilityIdentifier("amounts-hidden-indicator")
                    .allowsHitTesting(false)
            }
        }
        .privacySensitive(store.hideAmounts)
        .task(id: session.token) { [session] in
            store.configurePrivacy(userID: session.profile?.id)
            store.configureOnboarding(userID: session.profile?.id ?? (session.sourceMode == .deterministic ? "deterministic-demo-user" : nil))
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-guided-onboarding") {
                store.restartOnboarding()
            }
            store.bindLiveCredentialAuthority { forceRefresh in
                return try await session.currentLiveCredentials(forceRefresh: forceRefresh, caller: "workspace.request")
            }
            if let token = session.token, let serverURL = session.serverURL {
                store.updateLiveCredentials(serverURL: serverURL, token: token)
            }
            await reload()
            if !didEvaluateOnboarding {
                didEvaluateOnboarding = true
                showingOnboarding = !ProcessInfo.processInfo.arguments.contains("--skip-guided-onboarding")
                    && store.isGenuinelyEmptyForOnboarding
                    && !store.onboardingDismissed
                    && !store.onboardingCompleted
            }
        }
        .alert("Unable to complete request", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Retry") { Task { await reload() } }; Button("Cancel", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "Unknown error") }
        .sheet(isPresented: $showingSettings) {
            WorkspaceProfileView(store: store) {
                if store.onboardingCompleted { store.restartOnboarding() } else { store.resumeOnboarding() }
                showingOnboarding = true
            }
                .environmentObject(session)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingOnboarding) {
            GuidedOnboardingView(store: store) { tab in
                showingOnboarding = false
                tabSelection.wrappedValue = tab
            }
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
    @EnvironmentObject private var appearance: AppearancePreference
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BudgetWorkspaceStore
    let startOnboarding: () -> Void
    @State private var showHousehold = false
    @State private var showConnection = false
    @State private var showCreate = false
    @State private var showAppearance = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    LabeledContent("User", value: session.profile?.displayName ?? "Demo household owner")
                    LabeledContent("Active budget", value: store.budget.name)
                }
                Section("Privacy") {
                    Toggle("Hide Amounts", isOn: $store.hideAmounts)
                    .accessibilityIdentifier("hide-amounts-toggle")
                    Text("Masks monetary values throughout this budget and conceals the workspace in the app switcher.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Button { showAppearance = true } label: {
                        LabeledContent("Appearance", value: appearance.selection.title)
                    }
                    .accessibilityIdentifier("appearance-settings-action")
                    Text("System follows your iPhone appearance automatically. Light and Dark stay fixed on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                Section("Help & Education") {
                    Button(store.onboardingCompleted ? "Restart Guided Tour" : "Continue Guided Tour", systemImage: "graduationcap") {
                        dismiss(); startOnboarding()
                    }
                    Text("Learn with your real budget. The guide never creates accounts, balances, allocations, or transactions for you.").font(.footnote).foregroundStyle(.secondary)
                }
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
            .navigationDestination(isPresented: $showAppearance) { AppearanceSettingsView() }
            .sheet(isPresented: $showCreate) {
                BudgetCreationView(households: session.profile?.households.filter { $0.role == "owner" && $0.isActive } ?? [])
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearancePreference
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance.selection) {
                    ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("appearance-picker")
            } footer: {
                Text("This presentation preference is stored on this device. It does not change your budget or Hide Amounts setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuidedOnboardingView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    let openTab: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Int

    init(store: BudgetWorkspaceStore, openTab: @escaping (Int) -> Void) {
        self.store = store; self.openTab = openTab
        _step = State(initialValue: min(max(store.onboardingStep, 0), Self.lessons.count - 1))
    }

    private struct Lesson {
        let title: String; let symbol: String; let explanation: String; let consequence: String; let action: String; let tab: Int
    }
    private static let lessons = [
        Lesson(title: "Where money lives", symbol: "building.columns", explanation: "Accounts answer where your money is. Add real checking, savings, cash, and card balances in Accounts.", consequence: "Creating an account with an opening balance changes authoritative account and Ready to Assign values.", action: "Open Accounts", tab: 3),
        Lesson(title: "What money is for", symbol: "square.grid.2x2", explanation: "Your Plan gives current money a purpose. Categories do not create money; assigning moves Ready to Assign into a purpose.", consequence: "Creating groups/categories is organizational. Assigning money changes the Plan, not the bank balance.", action: "Open Plan", tab: 1),
        Lesson(title: "Record real activity", symbol: "plus.circle", explanation: "Transactions belong to accounts and spending categories. Posted spending reduces both the account balance and category Available.", consequence: "Saving a transaction changes authoritative financial data. Canceling its editor changes nothing.", action: "Open Activity", tab: 2),
        Lesson(title: "Adjust the plan", symbol: "arrow.left.arrow.right", explanation: "When priorities change, move available money between categories. A move conserves the total amount of household money.", consequence: "A move changes category purposes but not account balances or Ready to Assign.", action: "Open Plan", tab: 1),
        Lesson(title: "Plan ahead safely", symbol: "calendar.badge.clock", explanation: "Targets and schedules guide future decisions. Credit-card reserves protect funded purchases, and reconciliation confirms cleared reality.", consequence: "Targets and schedules are guidance only. Scheduled money becomes actual only when entered; reconciliation finalizes observed cleared activity.", action: "Open Plan", tab: 1),
        Lesson(title: "Forecast is not cash", symbol: "chart.line.uptrend.xyaxis", explanation: "Forecast includes future scheduled income and expenses. Future income can help you prepare, but it is not spendable until received.", consequence: "Viewing Forecast never changes balances, Available, or Ready to Assign.", action: "Open Home", tab: 0),
        Lesson(title: "Understand the story", symbol: "chart.xyaxis.line", explanation: "Insights explains spending, cash flow, net worth, debt, and plan performance from authorized posted history.", consequence: "Filters and charts are read-only and never alter financial records.", action: "Open Insights", tab: 4),
    ]
    private var lesson: Lesson { Self.lessons[step] }
    private var completionText: String {
        switch step {
        case 0: return store.accounts.isEmpty ? "Next useful action: add your first real account." : "You have \(store.accounts.filter { !$0.isClosed }.count) open account(s)."
        case 1: return store.categories.isEmpty ? "Next useful action: create a category group and category." : "Your Plan has \(store.categories.filter { !$0.isArchived }.count) active categories."
        case 2: return store.transactions.isEmpty ? "Next useful action: record your first transaction when real activity occurs." : "Your budget contains posted activity."
        default: return "Explore this in the production workspace whenever it is useful."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Image(systemName: lesson.symbol).font(.system(size: 34)).foregroundStyle(Theme.accent).accessibilityHidden(true); Spacer(); Text("\(step + 1) of \(Self.lessons.count)").font(.subheadline).foregroundStyle(.secondary).accessibilityLabel("Lesson \(step + 1) of \(Self.lessons.count)") }
                    Text(lesson.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(lesson.explanation).font(.title3)
                    GroupBox("What changes") { Text(lesson.consequence).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4) }
                    Label(completionText, systemImage: "lightbulb").foregroundStyle(.secondary)
                    Button(lesson.action) { store.saveOnboarding(step: min(step + 1, Self.lessons.count - 1)); openTab(lesson.tab) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .accessibilityHint("Closes the guide and opens the real workspace. No financial action is performed.")
                }
                .padding()
            }
            .navigationTitle("Guided Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { store.saveOnboarding(step: step, dismissed: true); dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back") { changeStep(-1) }.disabled(step == 0)
                    Spacer()
                    if step == Self.lessons.count - 1 { Button("Finish") { store.saveOnboarding(step: step, dismissed: false, completed: true); dismiss() }.fontWeight(.semibold) }
                    else { Button("Next") { changeStep(1) } }
                }
            }
        }
        .interactiveDismissDisabled(false)
        .onDisappear { if !store.onboardingCompleted && !store.onboardingDismissed { store.saveOnboarding(step: step) } }
        .accessibilityIdentifier("guided-onboarding")
    }
    private func changeStep(_ delta: Int) {
        let next = min(max(step + delta, 0), Self.lessons.count - 1)
        if reduceMotion { step = next } else { withAnimation(.easeInOut(duration: 0.2)) { step = next } }
        store.saveOnboarding(step: next)
    }
}

private struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill").font(.largeTitle)
                Text("Amounts Hidden").font(.headline)
                Text("Return to Budget App to continue.").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("privacy-app-switcher-shield")
        .allowsHitTesting(false)
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
    @State private var showTransaction = false
    @State private var showMoveMoney = false
    @State private var showSchedule = false
    @State private var showRequest = false
    @State private var editingCategory: APICategoryMonth?
    @State private var movePresentation: MoveMoneyPresentation?
    @State private var managingCategory: APICategory?
    private var planRows: [APICategoryMonth] { store.summary?.categories ?? [] }
    private var pendingRequests: [APIFinancialRequest] { store.requests.filter { $0.status == "pending" } }
    private var activeSchedules: [APIScheduledTransaction] {
        store.scheduledTransactions.filter(\.isActive).sorted { $0.nextDate < $1.nextDate }
    }
    private var attentionRows: [APICategoryMonth] {
        planRows
            .filter { $0.isOverspent || ($0.underfundedMinor ?? 0) > 0 }
            .sorted {
                if $0.isOverspent != $1.isOverspent { return $0.isOverspent }
                let left = $0.isOverspent ? abs($0.availableMinor) : ($0.underfundedMinor ?? 0)
                let right = $1.isOverspent ? abs($1.availableMinor) : ($1.underfundedMinor ?? 0)
                if left != right { return left > right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
    private var canMoveMoney: Bool { store.budget.can("move_money") && planRows.contains(where: { $0.availableMinor > 0 }) && planRows.count > 1 }
    private var hasQuickActions: Bool {
        (store.budget.can("create_transaction") && !store.accounts.filter({ !$0.isClosed }).isEmpty)
            || canMoveMoney || store.budget.can("manage_planning") || store.budget.can("request_money")
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.delegatedBudget == nil ? "AVAILABLE TO ASSIGN" : "AVAILABLE IN YOUR BUDGET").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(store.format(store.delegatedBudget?.availableToAssignMinor ?? store.summary?.readyToAssignMinor ?? 0)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(store.delegatedBudget == nil ? "Real money waiting for a purpose" : "Delegated money you control but have not categorized").foregroundStyle(.secondary)
                }.padding(.vertical, 10)
            }
            if hasQuickActions {
                Section("Quick actions") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                        if store.budget.can("create_transaction") && !store.accounts.filter({ !$0.isClosed }).isEmpty {
                            HomeQuickAction(title: "Transaction", symbol: "plus.circle.fill", identifier: "home-add-transaction") { showTransaction = true }
                        }
                        if canMoveMoney {
                            HomeQuickAction(title: "Move Money", symbol: "arrow.left.arrow.right.circle.fill", identifier: "home-move-money") { showMoveMoney = true }
                        }
                        if store.budget.can("manage_planning") {
                            HomeQuickAction(title: "Schedule", symbol: "calendar.badge.plus", identifier: "home-add-schedule") { showSchedule = true }
                        }
                        if store.budget.can("request_money") {
                            HomeQuickAction(title: "Request", symbol: "hand.raised.fill", identifier: "home-request-money") { showRequest = true }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if store.summary != nil && (!attentionRows.isEmpty || !pendingRequests.isEmpty) {
                Section("Needs attention") {
                    ForEach(attentionRows.prefix(5)) { row in
                        NavigationLink {
                            LivePlanCategoryDetailView(
                                categoryID: row.categoryID,
                                assign: { editingCategory = row },
                                move: { movePresentation = .init(sourceCategoryID: row.categoryID) },
                                manage: { managingCategory = store.categories.first(where: { $0.id == row.categoryID }) }
                            )
                        } label: {
                            HomeAttentionRow(category: row)
                        }
                        .accessibilityIdentifier("home-attention-category-\(row.categoryID)")
                    }
                    if attentionRows.count > 5 {
                        Text("\(attentionRows.count - 5) more categor\(attentionRows.count - 5 == 1 ? "y" : "ies") need attention in Plan.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pendingRequests) { request in NavigationLink { LiveRequestDetailView(requestID: request.id) } label: { Label("Request pending · \(store.format(request.requestedAmountMinor))", systemImage: "hand.raised.fill") } }
                }
            }
            if !store.isLoading {
                Section("Upcoming") {
                    if activeSchedules.isEmpty {
                        ContentUnavailableView("No upcoming schedules", systemImage: "calendar", description: Text("Paused schedules stay out of forecasts until reactivated."))
                            .accessibilityIdentifier("home-upcoming-empty")
                    } else {
                        ForEach(Array(activeSchedules.prefix(3))) { item in NavigationLink { LiveScheduledTransactionEditor(schedule: item, currencyCode: store.budget.currencyCode) } label: { ScheduledTransactionRow(item: item) } }
                        NavigationLink("View all scheduled transactions") { LiveScheduledTransactionsView() }
                    }
                }
            }
            if !store.isLoading {
                Section("Recent activity") {
                    if store.transactions.isEmpty {
                        ContentUnavailableView("No posted activity yet", systemImage: "clock", description: Text("Posted transactions will appear here."))
                            .accessibilityIdentifier("home-recent-empty")
                    } else {
                        ForEach(store.transactions.prefix(5)) { LiveTransactionLink(transaction: $0) }
                    }
                }
            }
            if let forecast = store.forecast { Section("90-day forecast") { LabeledContent("Projected total", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest projected", value: store.format(forecast.lowestProjectedTotalMinor)); NavigationLink("View forecast") { LiveForecastView() } } }
        }
        .navigationTitle(store.budget.name)
        .sheet(isPresented: $showTransaction) {
            TransactionEntryView(budget: store.budget, accounts: store.accounts, categories: store.categories, onSaved: store.refresh)
        }
        .sheet(isPresented: $showMoveMoney) {
            if let summary = store.summary {
                AllocationTransferView(budget: store.budget, categories: summary.categories, expectedAllocationVersion: summary.allocationVersion, onSaved: store.refresh)
            }
        }
        .sheet(isPresented: $showSchedule) { LiveScheduledTransactionEditor(schedule: nil, currencyCode: store.budget.currencyCode) }
        .sheet(isPresented: $showRequest) { FundingRequestView(budget: store.budget, categories: store.categories, onSaved: store.refresh) }
        .sheet(item: $editingCategory) { category in
            if let summary = store.summary {
                AssignmentEditView(budget: store.budget, category: category, month: String(BudgetWorkspaceStore.dateString(store.planMonth).prefix(7)) + "-01", expectedAllocationVersion: summary.allocationVersion, onSaved: store.refresh)
            }
        }
        .sheet(item: $movePresentation) { presentation in
            if let summary = store.summary {
                AllocationTransferView(budget: store.budget, categories: summary.categories, expectedAllocationVersion: summary.allocationVersion, initialSourceCategoryID: presentation.sourceCategoryID, onSaved: store.refresh)
            }
        }
        .sheet(item: $managingCategory) { category in
            LiveCategoryEditView(budget: store.budget, category: category, groups: store.groups, members: store.householdMembers, onSaved: store.refresh)
        }
    }
}

private struct HomeAttentionRow: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let category: APICategoryMonth
    private var isOverspent: Bool { category.isOverspent }
    private var amount: Int64 { isOverspent ? abs(category.availableMinor) : (category.underfundedMinor ?? 0) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isOverspent ? ((category.creditOverspentMinor ?? 0) > 0 && (category.cashOverspentMinor ?? 0) == 0 ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill") : "target")
                .foregroundStyle(isOverspent ? Theme.danger : Theme.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                Text(isOverspent ? (store.overspendSummary(category) ?? "Overspent") : "Target needs \(store.format(amount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.format(amount))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(isOverspent ? Theme.danger : Theme.attention)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this category's resolution actions")
    }
}

private struct HomeQuickAction: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }
}

private struct LiveForecastView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { if let forecast = store.forecast { Section { Text("Projected values include schedules but are not spendable until entered.").font(.footnote).foregroundStyle(.secondary) }; Section("Household cash") { LabeledContent("Today", value: store.format(forecast.actualTotalOnBudgetMinor)); LabeledContent("At \(forecast.through)", value: store.format(forecast.projectedTotalOnBudgetMinor)); LabeledContent("Lowest", value: store.format(forecast.lowestProjectedTotalMinor)) }; Section("Accounts") { ForEach(forecast.accounts) { account in VStack(alignment: .leading) { Text(account.name); HStack { Text("Now \(store.format(account.actualBalanceMinor))"); Spacer(); Text("Projected \(store.format(account.projectedBalanceMinor))") }.font(.caption).foregroundStyle(.secondary) } } }; Section("Scheduled activity") { if forecast.occurrences.isEmpty { Text("No scheduled transactions in this period").foregroundStyle(.secondary) }; ForEach(forecast.occurrences) { item in if let schedule = store.scheduledTransactions.first(where: { $0.id == item.scheduledTransactionID }) { NavigationLink { LiveScheduledTransactionEditor(schedule: schedule, currencyCode: store.budget.currencyCode) } label: { ScheduledActivityPresentation(name: item.name, amountMinor: item.amountMinor, occurrenceDate: item.occurredOn, context: item.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }) } } else { ScheduledActivityPresentation(name: item.name, amountMinor: item.amountMinor, occurrenceDate: item.occurredOn, context: nil) } } } } }.navigationTitle("Forecast") }
}

private struct LiveRequestDetailView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let requestID: String
    @State private var amount = ""; @State private var sourceCategoryID = ""; @State private var note = ""; @State private var isSaving = false; @State private var errorMessage: String?
    @State private var showRevise = false; @State private var confirmCancel = false
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
                    LabeledContent("Status", value: request.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    if let expiresAt = request.expiresAt, ["pending", "changes_requested"].contains(request.status) { LabeledContent("Expires", value: expiresAt) }
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
                if request.requesterUserID == session.profile?.id && ["pending", "changes_requested"].contains(request.status) {
                    Section("Your request") {
                        if request.status == "changes_requested" { Button("Revise and Resubmit") { showRevise = true } }
                        Button("Cancel Request", role: .destructive) { confirmCancel = true }
                    }
                }
                Section("History") {
                    ForEach(request.actions) { action in
                        VStack(alignment: .leading) {
                            Text(action.action.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text(action.actorUserID.flatMap(requesterName) ?? "System").font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: $showRevise) { if let request { FundingRequestView(budget: store.budget, categories: store.categories, request: request, onSaved: store.refresh) } }
        .confirmationDialog("Cancel this request?", isPresented: $confirmCancel, titleVisibility: .visible) { Button("Cancel Request", role: .destructive) { Task { await cancel() } } } message: { Text("The request and its decision history remain visible, but it can no longer be approved.") }
    }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: store.budget.currencyCode), value > 0, value <= (request?.requestedAmountMinor ?? 0) else { return nil }; return value }
    private func requesterName(_ id: String) -> String { store.householdMembers.first(where: { $0.userID == id })?.displayName ?? id.capitalized }
    private func cancel() async { guard let request else { return }; isSaving = true; defer { isSaving = false }; do { try await store.cancelRequest(id: request.id, version: request.version, note: note) } catch { errorMessage = error.localizedDescription } }
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
    private var rows: [APICategoryMonth] {
        let filtered = (store.summary?.categories ?? []).filter { row in
            switch focus {
            case .all: true
            case .favorites: store.categories.first(where: { $0.id == row.categoryID })?.isFavorite == true
            case .underfunded: (row.underfundedMinor ?? 0) > 0
            case .overspent: row.isOverspent
            case .funded: (row.underfundedMinor ?? 0) == 0 && !row.isOverspent
            case .available: row.availableMinor > 0
            }
        }
        guard focus == .favorites else { return filtered }
        return filtered.sorted { left, right in
            let leftModel = store.categories.first(where: { $0.id == left.categoryID })
            let rightModel = store.categories.first(where: { $0.id == right.categoryID })
            let leftOrder = leftModel?.favoriteSortOrder ?? Int.max
            let rightOrder = rightModel?.favoriteSortOrder ?? Int.max
            return leftOrder == rightOrder ? left.name.localizedStandardCompare(right.name) == .orderedAscending : leftOrder < rightOrder
        }
    }
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

private enum PlanFocus: String, CaseIterable, Identifiable { case all = "All", favorites = "Favorites", underfunded = "Underfunded", overspent = "Overspent", funded = "Funded", available = "Available"; var id: Self { self } }

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
    @State private var errorMessage: String?
    private var row: APICategoryMonth? { store.summary?.categories.first { $0.categoryID == categoryID } }
    private var model: APICategory? { store.categories.first { $0.id == categoryID } }
    private var transactions: [APITransaction] { store.transactions.filter { $0.categoryID == categoryID || $0.splits.contains(where: { $0.categoryID == categoryID }) } }
    private var operations: [(APIAllocationOperation, APIAllocationPosting)] { store.allocationOperations.flatMap { operation in operation.postings.filter { $0.categoryID == categoryID }.map { (operation, $0) } } }
    var body: some View { List { if let row { Section("Plan") { LabeledContent("Available", value: store.format(row.availableMinor)); LabeledContent("Assigned this month", value: store.format(row.assignedMinor)); LabeledContent("Activity this month", value: store.format(row.activityMinor)); LabeledContent("Rollover into month", value: store.format(row.carriedAvailableMinor)); if row.targetType != nil { LabeledContent("Target recommendation", value: store.format(row.recommendedContributionMinor ?? 0)); LabeledContent("Still needed", value: store.format(row.underfundedMinor ?? 0)); if let date = row.targetDate { LabeledContent("Due", value: date) } }; if let overspend = store.overspendSummary(row) { VStack(alignment: .leading, spacing: 2) { Label(overspend, systemImage: (row.creditOverspentMinor ?? 0) > 0 && (row.cashOverspentMinor ?? 0) == 0 ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill").foregroundStyle(Theme.danger); Text((row.creditOverspentMinor ?? 0) > 0 ? "Unfunded card spending adds to card debt; fund the card payment category to cover it." : "Move available money here or reduce spending to cover the shortfall.").font(.caption).foregroundStyle(.secondary) } } }; Section("Actions") { if store.budget.can("assign_money") { Button("Assign money", action: assign) }; if store.budget.can("move_money") { Button("Move money", action: move) }; if store.budget.can("manage_planning") { Button(store.targets[categoryID] == nil ? "Create target" : "Manage target") { showTarget = true } }; if let model { Button(model.isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: model.isFavorite ? "star.slash" : "star") { Task { do { try await store.setCategoryFavorite(id: categoryID, isFavorite: !model.isFavorite) } catch { errorMessage = error.localizedDescription } } }.accessibilityIdentifier("category-favorite-action"); Button("Edit category", action: manage) } } }; let schedules = store.scheduledTransactions.filter { $0.isActive && $0.categoryID == categoryID }; if !schedules.isEmpty { Section("Upcoming scheduled") { ForEach(schedules) { item in NavigationLink { LiveScheduledTransactionEditor(schedule: item, currencyCode: store.budget.currencyCode) } label: { ScheduledTransactionRow(item: item) } } } }; Section("Recent activity") { if transactions.isEmpty { Text("No contributing transactions").foregroundStyle(.secondary) }; ForEach(transactions.prefix(20)) { LiveTransactionLink(transaction: $0) } }; Section("Allocation history") { if operations.isEmpty { Text("No allocation movements available").foregroundStyle(.secondary) }; ForEach(Array(operations.enumerated()), id: \.offset) { _, value in VStack(alignment: .leading) { Text(value.0.note.isEmpty ? value.0.kind.replacingOccurrences(of: "_", with: " ").capitalized : value.0.note); HStack { Text(value.0.occurredOn); Spacer(); Text(store.format(value.1.amountMinor)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary) } } } }.navigationTitle(row?.name ?? "Category").sheet(isPresented: $showTarget) { LiveTargetEditor(categoryID: categoryID, categoryName: row?.name ?? "Category", currencyCode: store.budget.currencyCode, existing: store.targets[categoryID]) }.alert("Unable to update favorite", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } }
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
                        LabeledContent("Before", value: workspace.format(preview.beforeReadyToAssignMinor))
                        LabeledContent("Proposed", value: workspace.format(-preview.proposedMinor))
                        LabeledContent("After", value: workspace.format(preview.afterReadyToAssignMinor))
                    }
                    Section("Target recommendations") { ForEach(preview.proposals) { proposal in LabeledContent(proposal.categoryName, value: workspace.format(proposal.amountMinor)) } }
                } else if !isLoading { ContentUnavailableView("No funding preview", systemImage: "sparkles") }
            }.navigationTitle("Smart Funding").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Confirm"){Task{await commit()}}.disabled(preview?.proposals.isEmpty != false || isLoading)} }
                .overlay { if isLoading { ProgressView() } }.task { await load() }
                .alert("Unable to fund plan",isPresented:Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})){Button("OK",role:.cancel){}}message:{Text(errorMessage ?? "Unknown error")}
        }
    }
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
                Section("Details") { LabeledContent("Payee", value: transaction.payeeName); if let linked = linkedAccountName(for: transaction) { LabeledContent("Linked account", value: linked) } else { LabeledContent("Category", value: store.categoryName(transaction)) }; LabeledContent("Date", value: transaction.occurredOn); LabeledContent("Posting") { Text((transaction.status ?? "posted").uppercased()).accessibilityIdentifier("transaction-posting-status") }; LabeledContent("Clearing") { Text(transaction.isReconciled ? "Reconciled" : transaction.isCleared ? "Cleared" : "Uncleared").accessibilityIdentifier("transaction-status") }; LabeledContent("Classification", value: transaction.financialClassification == "interest_charge" || transaction.splits.contains(where: { $0.financialClassification == "interest_charge" }) ? "Interest charge" : "Ordinary transaction"); LabeledContent("Memo", value: transaction.memo.isEmpty ? "—" : transaction.memo); LabeledContent("Flag", value: transaction.flag?.capitalized ?? "None"); LabeledContent("Tags", value: transaction.tags?.isEmpty == false ? transaction.tags!.map { "#\($0)" }.joined(separator: " ") : "None") }
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
        .navigationDestination(item: $previewURL) { url in
            AttachmentPreviewScreen(url: url) {
                var dismissal = Transaction(animation: nil)
                dismissal.disablesAnimations = true
                withTransaction(dismissal) { previewURL = nil }
            }
        }
        .confirmationDialog("Remove Attachment?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible, presenting: pendingRemoval) { attachment in
            Button("Remove Attachment", role: .destructive) { pendingRemoval = nil; Task { await detach(attachment) } }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { attachment in Text(removalMessage(for: attachment)) }
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
    private func removalMessage(for attachment: APITransactionAttachment) -> String {
        attachment.filename + " will be detached and retained for 30 days before permanent deletion."
    }
    private func detach(_ attachment: APITransactionAttachment) async { do { try await store.detachTransactionAttachment(transactionID: transaction.id, attachmentID: attachment.id); await load() } catch { self.error = error.localizedDescription } }
}

private struct AttachmentPreviewScreen: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        AttachmentPreviewController(url: url)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward") { onDismiss() }
                        .accessibilityIdentifier("attachment-preview-back")
                }
            }
    }
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
    static func dismantleUIViewController(_ uiViewController: QLPreviewController, coordinator: Coordinator) {
        uiViewController.dataSource = nil
        try? FileManager.default.removeItem(at: coordinator.url)
    }
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

private struct ReportLoadModifier: ViewModifier {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let kinds: Set<WorkspaceReportKind>
    var suspended = false
    private struct LoadKey: Equatable {
        let context: WorkspaceReportContext
        let suspended: Bool
    }
    func body(content: Content) -> some View {
        let ready = store.reportsReady(kinds)
        let errors = kinds.compactMap { store.reportErrors[$0] }
        content
            .opacity(ready ? 1 : 0)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)
            .overlay {
                if !ready {
                    if let error = errors.first {
                        ContentUnavailableView {
                            Label("Unable to load report", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        } description: { Text(error) } actions: {
                            Button("Retry") { Task { await store.loadReports(kinds, retry: true) } }
                            Button("Reset range and filters") { store.resetReportSelection() }
                        }
                    } else { ProgressView("Loading report…") }
                }
            }
            .task(id: LoadKey(context: store.reportContext, suspended: suspended)) {
                if !suspended { await store.loadReports(kinds) }
            }
    }
}

private struct LiveInsightsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var showFilters = false
    @State private var breakdownMode = SpendingBreakdownMode.category
    @State private var selectedAngle: Int64?
    @State private var selectedSlice: SpendingBreakdownSlice?
    @State private var showReportPayeeSelector = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    var body: some View {
        List {
            Section("Financial Snapshot") {
                if let worth = store.insightsSummary?.netWorthMinor { LabeledContent("Net worth", value: store.format(worth)) }
                if let cash = store.insightsSummary?.netCashFlowMinor { LabeledContent("Net cash flow", value: store.format(cash)) }
                if let summary = store.summary { LabeledContent("Ready to assign", value: store.format(summary.readyToAssignMinor)) }
                if let debt = store.insightsSummary?.debtMinor {
                    LabeledContent("Total debt", value: store.format(debt))
                }
                if let interest = store.insightsSummary?.recordedInterestMonthMinor { LabeledContent("Recorded interest this month", value: store.format(interest)) }
            }
            Section("Reports") {
                NavigationLink { SpendingIncomeReportView() } label: { reportLink("Spending & Income", "Where money came from and where it went.", "chart.pie") }.accessibilityIdentifier("insights-spending-income")
                NavigationLink { PlanPerformanceReportView() } label: { reportLink("Plan Performance", "Assignments, activity, targets, and overspending.", "target") }.accessibilityIdentifier("insights-plan-performance")
                NavigationLink { NetWorthDestinationView() } label: { reportLink("Net Worth", "Assets, liabilities, and change over time.", "chart.line.uptrend.xyaxis") }.accessibilityIdentifier("insights-net-worth")
                NavigationLink { DebtInterestDestinationView() } label: { reportLink("Debt & Interest", "Balances, recorded interest, and payoff planning.", "creditcard.trianglebadge.exclamationmark") }.accessibilityIdentifier("insights-debt-interest")
            }
            if let margin = store.insightsSummary?.expectedMarginMinor { Section("Looking Ahead") { LabeledContent("Expected 30-day margin", value: store.format(margin)); Text("Forecast-only scheduled income and outflows. It does not change money available today.").font(.caption).foregroundStyle(.secondary) } }
        }.modifier(ReportLoadModifier(kinds: [.summary], suspended: showFilters))
        .navigationTitle("Insights").accessibilityIdentifier("insights-hub")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Label("Report Filters", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }.accessibilityIdentifier("insights-report-filters")
            }
        }
        .sheet(isPresented: $showFilters) { filters.environmentObject(store) }
        .alert("Unable to export reports", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "Unknown error") }
    }
    private func reportLink(_ title: String, _ explanation: String, _ symbol: String) -> some View { Label { VStack(alignment: .leading, spacing: 3) { Text(title); Text(explanation).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol).foregroundStyle(Theme.accent) } }
    private var hasFilters: Bool { !store.reportAccountID.isEmpty || !store.reportCategoryID.isEmpty || !store.reportCategoryGroup.isEmpty || !store.reportPayee.isEmpty || !store.reportMemberID.isEmpty || !store.reportTransactionType.isEmpty || store.reportCleared != "all" || !store.reportFlag.isEmpty || !store.reportTag.isEmpty || store.includeTrackingAccounts }
    private var filters: some View { NavigationStack { Form {
        Picker("Account", selection: $store.reportAccountID) { Text("All accounts").tag(""); ForEach(store.accounts) { Text($0.name).tag($0.id) } }
        Picker("Category", selection: $store.reportCategoryID) { Text("All categories").tag(""); ForEach(store.categories.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } }
        Picker("Category group", selection: $store.reportCategoryGroup) { Text("All groups").tag(""); ForEach(store.groups) { Text($0.name).tag($0.name) } }
        Button { showReportPayeeSelector = true } label: { LabeledContent("Payee", value: store.reportPayee.isEmpty ? "All payees" : store.reportPayee) }
        if !store.reportPayee.isEmpty { Button("Clear Payee Filter", role: .destructive) { store.reportPayee = "" } }
        if !store.householdMembers.isEmpty { Picker("Member", selection: $store.reportMemberID) { Text("All members").tag(""); ForEach(store.householdMembers.filter(\.isActive)) { Text($0.displayName).tag($0.userID) } } }
        Picker("Type", selection: $store.reportTransactionType) { Text("All types").tag(""); Text("Spending").tag("spending"); Text("Refunds").tag("refund"); Text("Income").tag("income"); Text("Transfers").tag("transfer"); Text("Interest charges").tag("interest_charge") }
        Picker("Status", selection: $store.reportCleared) { Text("All statuses").tag("all"); Text("Cleared").tag("cleared"); Text("Uncleared").tag("uncleared"); Text("Reconciled").tag("reconciled") }
        TextField("Flag", text: $store.reportFlag).textInputAutocapitalization(.never)
        TextField("Tag", text: $store.reportTag).textInputAutocapitalization(.never)
        Toggle("Include tracking accounts", isOn: $store.includeTrackingAccounts)
    }.navigationTitle("Report Filters").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Reset") { store.reportAccountID = ""; store.reportCategoryID = ""; store.reportCategoryGroup = ""; store.reportPayee = ""; store.reportMemberID = ""; store.reportTransactionType = ""; store.reportCleared = "all"; store.reportFlag = ""; store.reportTag = ""; store.includeTrackingAccounts = false } }; ToolbarItem(placement: .confirmationAction) { Button("Apply") { showFilters = false } } }.sheet(isPresented: $showReportPayeeSelector) { PayeeSearchSelectionView(title: "Filter by Payee") { store.reportPayee = $0.displayName } } } }
    private func reload() async { await store.refresh() }
    private func prepareExport() async {
        do { exportURL = try await store.exportReports() }
        catch { exportError = error.localizedDescription }
    }
}

private struct ReportPeriodControls: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    var body: some View {
        Section("Period") {
            Picker("Period", selection: $store.reportPeriod) {
                Text("30 Days").tag("30d"); Text("60 Days").tag("60d"); Text("90 Days").tag("90d")
                Text("3 Months").tag("3m"); Text("6 Months").tag("6m")
                Text("Year to Date").tag("ytd"); Text("1 Year").tag("1y"); Text("Custom").tag("custom")
            }.accessibilityIdentifier("report-period")
            if store.reportPeriod == "custom" {
                DatePicker("From", selection: $draftStart, displayedComponents: .date)
                DatePicker("Through", selection: $draftEnd, displayedComponents: .date)
                Button("Apply custom range") {
                    store.customReportStart = draftStart
                    store.customReportEnd = draftEnd
                }
            }
        }.onAppear {
            draftStart = store.customReportStart; draftEnd = store.customReportEnd
        }
        .onChange(of: store.customReportStart) { _, value in draftStart = value }
        .onChange(of: store.customReportEnd) { _, value in draftEnd = value }
    }
}

private struct SpendingIncomeReportView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var mode = SpendingBreakdownMode.category
    @State private var angle: Int64?; @State private var slice: SpendingBreakdownSlice?
    @State private var exportURL: URL?; @State private var exportError: String?
    var body: some View { List {
        ReportPeriodControls()
        if let income=store.incomeReport { IncomeSpendingTrendsView(report:income) }
        if let spending=store.spendingReport { SpendingBreakdownView(report:spending,mode:$mode,selectedAngle:$angle,selectedSlice:$slice);Section("Ranked breakdown"){ForEach(SpendingBreakdownSlice.make(from:spending,mode:mode)){item in Button{slice=item}label:{LabeledContent(item.name,value:store.format(item.spendingMinor))}}} }
        else { ContentUnavailableView("No spending in this range",systemImage:"chart.pie",description:Text("Try a wider date range.")) }
        if let trends=store.spendingTrendsReport { SpendingTrendsView(report:trends) }
        if store.budget.can("export_data") { Section("Export") { if let exportURL { ShareLink(item:exportURL){Label("Share Report CSV",systemImage:"square.and.arrow.up")}.accessibilityIdentifier("share-report-csv") };Button{Task{do{exportURL=try await store.exportReports()}catch{exportError=error.localizedDescription}}}label:{Label(exportURL == nil ? "Prepare Report CSV":"Refresh Report CSV",systemImage:"tablecells")}.accessibilityIdentifier("prepare-report-csv") } }
}.modifier(ReportLoadModifier(kinds: [.spending, .spendingTrends, .income])).navigationTitle("Spending & Income").navigationDestination(item:$slice){item in if item.mode == .group {LiveReportGroupView(group:item.name)} else if let category=store.spendingReport?.categories.first(where:{$0.categoryID==item.id}){LiveReportCategoryView(category:category)}}.alert("Unable to export reports",isPresented:Binding(get:{exportError != nil},set:{if !$0{exportError=nil}})){Button("OK",role:.cancel){}}message:{Text(exportError ?? "Unknown error")} }
}

private struct PlanPerformanceReportView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { ReportPeriodControls(); if let summary=store.summary { BudgetPerformanceInsightsView(summary:summary) }; if let report=store.planPerformanceReport { HistoricalPlanPerformanceView(report:report) } else { ContentUnavailableView("No planning history",systemImage:"target",description:Text("Assignments and category activity will appear here.")) } }.modifier(ReportLoadModifier(kinds: [.planPerformance])).navigationTitle("Plan Performance").accessibilityIdentifier("insights-plan-report") }
}

private struct NetWorthDestinationView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    var body: some View { List { ReportPeriodControls(); if let report=store.netWorthReport { NetWorthReportView(report:report) } else { ContentUnavailableView("No account history",systemImage:"chart.line.uptrend.xyaxis",description:Text("Add an account balance or widen the date range.")) } }.modifier(ReportLoadModifier(kinds: [.netWorth])).navigationTitle("Net Worth") }
}

private struct DebtInterestDestinationView: View {
    enum SectionChoice:String,CaseIterable {case overview="Overview",interest="Interest",payoff="Payoff"}
    @EnvironmentObject private var store: BudgetWorkspaceStore
    @State private var choice=SectionChoice.overview
    @State private var editingTermsAccount: APIAccount?
    @State private var termsRevision = 0
    var body: some View { List { Section { Picker("Debt section",selection:$choice){ForEach(SectionChoice.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented).accessibilityIdentifier("debt-insights-sections") }
        if choice != .payoff { ReportPeriodControls() }
        if let report=store.debtReport { switch choice { case .overview: DebtOverviewContent(report:report); case .interest: DebtInterestContent(report:report); case .payoff: DebtPayoffContent(report: report, editingTermsAccount: $editingTermsAccount, termsRevision: termsRevision) } }
        else { ContentUnavailableView("No debt",systemImage:"checkmark.circle",description:Text("Credit cards and loans will appear here when visible.")) }
    }.modifier(ReportLoadModifier(kinds: [.debt])).navigationTitle("Debt & Interest")
        .sheet(item: $editingTermsAccount, onDismiss: { termsRevision += 1 }) { account in
            DebtTermsEditorView(account: account).environmentObject(store)
        }
    }
}

private struct DebtOverviewContent: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIDebtReport
    var body: some View {
        Section("Recorded debt") {
            LabeledContent("Before \(report.startDate)", value: store.format(report.openingDebtMinor))
            LabeledContent("Debt as of \(report.endDate)", value: store.format(report.debtMinor))
                .accessibilityIdentifier("recorded-debt-as-of")
            LabeledContent(report.principalReductionMinor >= 0 ? "Net debt decrease" : "Net debt increase",
                           value: store.format(abs(report.principalReductionMinor)))
            Text("Recorded balances include borrowing, payments, interest and adjustments. Net debt change is not a measure of principal payments alone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Debt accounts as of \(report.endDate)") {
            ForEach(report.accounts) { row in
                if let account = store.accounts.first(where: { $0.id == row.accountID }) {
                    NavigationLink { LiveAccountRegisterView(initialAccount: account) } label: {
                        LabeledContent(row.accountName, value: store.format(row.debtMinor))
                    }
                }
            }
        }
    }
}
private struct DebtInterestContent: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIDebtReport
    var body: some View {
        Section("Recorded Interest") {
            LabeledContent("Selected range", value: store.format(report.recordedInterestRangeMinor)).accessibilityIdentifier("recorded-interest-range")
            LabeledContent("This month", value: store.format(report.recordedInterestMonthMinor))
            LabeledContent("Year to date", value: store.format(report.recordedInterestYTDMinor))
            LabeledContent("Trailing 12 months", value: store.format(report.recordedInterestTrailing12Minor))
            if let recorded = report.recordedInterestLifetimeMinor {
                LabeledContent("All recorded through \(report.endDate)", value: store.format(recorded))
                    .accessibilityIdentifier("recorded-interest-lifetime")
            }
            Text(report.interestTrackingStartedOn.map { "Recorded since \($0). Earlier interest may not be classified." } ?? "No explicitly classified interest is recorded for this period.").font(.caption).foregroundStyle(.secondary)
        }
        Section("By Account") { ForEach(report.accounts.filter { $0.recordedInterestMinor != 0 }) { row in LabeledContent(row.accountName, value: store.format(row.recordedInterestMinor)) } }
    }
}

private struct DebtPayoffContent: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIDebtReport
    @Binding var editingTermsAccount: APIAccount?
    let termsRevision: Int
    @State private var strategy = "avalanche"
    @State private var rollover = true
    @State private var extraPreset: Int64 = 0
    @State private var customExtra = ""
    @State private var customOrder: [String] = []
    @State private var result: APIDebtStrategyProjection?
    @State private var baseline: APIDebtStrategyProjection?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var extraPayment: Int64? {
        if extraPreset >= 0 { return extraPreset }
        guard let value = CurrencyText.parseMinorUnits(customExtra, currencyCode: store.budget.currencyCode), value >= 0 else { return nil }
        return value
    }
    private var selectedAccountIDs: [String] { store.reportAccountID.isEmpty ? [] : [store.reportAccountID] }
    private var scenarioKey: String { "\(strategy)|\(rollover)|\(extraPayment.map(String.init) ?? "invalid")|\(customOrder.joined(separator: ","))|\(selectedAccountIDs.joined(separator: ","))|\(termsRevision)|\(store.reportRevision)|\(store.liveCredentialRevision)" }

    var body: some View {
        Section("Scenario") {
            Picker("Payoff strategy", selection: $strategy) {
                Text("Avalanche").tag("avalanche")
                Text("Snowball").tag("snowball")
                Text("Custom").tag("custom")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("debt-payoff-strategy")
            Text(strategyExplanation).font(.caption).foregroundStyle(.secondary)
            Toggle("Roll payments into the next debt", isOn: $rollover)
                .accessibilityIdentifier("debt-payoff-rollover")
            Text(rollover ? "Projected payments freed by a paid debt are applied to the next debt." : "Each debt keeps only its existing planned payment after another debt is paid.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Pay more each month", selection: $extraPreset) {
                Text("Current plan").tag(Int64(0)); Text("+$50").tag(Int64(5_000)); Text("+$100").tag(Int64(10_000)); Text("+$250").tag(Int64(25_000)); Text("Custom").tag(Int64(-1))
            }
            if extraPreset == -1 {
                CurrencyAmountField("Extra each month", text: $customExtra, currencyCode: store.budget.currencyCode, allowsZero: true)
                    .accessibilityIdentifier("debt-payoff-custom-extra")
            }
        }
        if strategy == "custom" { customOrderSection }
        if isLoading { Section { HStack { Spacer(); ProgressView("Calculating projected payoff…"); Spacer() } } }
        if let result { resultSections(result) }
        if store.budget.can("manage_budget_structure") {
            Section("Debt Terms") {
                ForEach(report.accounts) { row in
                    if let account = store.accounts.first(where: { $0.id == row.accountID }) {
                        Button { editingTermsAccount = account } label: {
                            Label("\(row.accountName) Debt Terms", systemImage: "percent")
                        }
                        .accessibilityIdentifier("payoff-debt-terms-\(row.accountID)")
                    }
                }
            }
        }
        Section {
            Label("Read-only scenario", systemImage: "lock.shield")
                .accessibilityIdentifier("debt-payoff-read-only")
            Text("Projected results use current visible balances and saved Debt Terms. Changing this scenario does not alter transactions, balances, Plan assignments, schedules, or debt terms.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Payments are normalized to a fixed monthly scenario budget. Actual weekly or biweekly payment dates are not modeled here. Saved APRs remain constant except for an explicit promotional expiry; unknown future rate changes are not predicted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: scenarioKey) {
            guard extraPayment != nil, !report.accounts.isEmpty else { result = nil; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await calculate()
        }
        .onAppear { if customOrder.isEmpty { customOrder = report.accounts.map(\.accountID) } }
        .alert("Unable to calculate payoff", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    @ViewBuilder private var customOrderSection: some View {
        Section("Custom priority") {
            ForEach(Array(customOrder.enumerated()), id: \.element) { index, id in
                HStack {
                    Text("\(index + 1). \(accountName(id))")
                    Spacer()
                    Button("Move up", systemImage: "chevron.up") { move(id, by: -1) }.labelStyle(.iconOnly).disabled(index == 0)
                    Button("Move down", systemImage: "chevron.down") { move(id, by: 1) }.labelStyle(.iconOnly).disabled(index == customOrder.count - 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Priority \(index + 1), \(accountName(id))")
            }
        }
    }

    @ViewBuilder private func resultSections(_ value: APIDebtStrategyProjection) -> some View {
        if value.status == "incomplete" {
            Section("Projection unavailable") {
                ForEach(value.incompleteAccounts, id: \.accountID) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName(item.accountID)).font(.headline)
                        Text("Add \(item.missingProjectionFields.map(friendlyMissingField).joined(separator: ", ")) in Debt Terms.").font(.caption).foregroundStyle(.secondary)
                        if store.budget.can("manage_budget_structure"),
                           let account = store.accounts.first(where: { $0.id == item.accountID }) {
                            Button("Add Debt Terms") { editingTermsAccount = account }
                                .accessibilityIdentifier("payoff-missing-terms-\(item.accountID)")
                        } else {
                            Text("Ask a household member with account-management access to complete these terms.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if value.status == "non_amortizing" {
            Section("Projection unavailable") {
                Label("Current planned payments do not reduce total principal under these assumptions.", systemImage: "exclamationmark.triangle")
                Text("Increase the projected payment or review saved APR and payment terms. No fictional debt-free date is shown.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Projected outcome") {
                LabeledContent("Projected debt-free date", value: value.debtFreeDate ?? "Beyond projection range")
                LabeledContent("Projected remaining interest", value: store.format(value.projectedInterestMinor))
                LabeledContent("Total projected cost", value: store.format(value.projectedTotalCostMinor))
                LabeledContent("Projected months", value: "\(value.paymentCount)")
                if let baseline, baseline.status == "paid_off" {
                    let interestDifference = baseline.projectedInterestMinor - value.projectedInterestMinor
                    let monthDifference = baseline.paymentCount - value.paymentCount
                    LabeledContent(interestDifference >= 0 ? "Projected interest avoided" : "Additional projected interest", value: store.format(abs(interestDifference)))
                    LabeledContent(monthDifference >= 0 ? "Projected time saved" : "Additional projected months", value: "\(abs(monthDifference)) month\(abs(monthDifference) == 1 ? "" : "s")")
                }
            }
            .accessibilityIdentifier("debt-payoff-outcome")
            Section("Projected payoff order") {
                ForEach(Array(value.payoffOrder.enumerated()), id: \.element) { index, id in
                    LabeledContent(accountName(id), value: "\(index + 1)")
                }
            }
        }
    }

    private var strategyExplanation: String {
        switch strategy {
        case "snowball": "Snowball directs scenario money to the lowest visible balance first."
        case "custom": "Custom follows the priority you set below."
        default: "Avalanche directs scenario money to the highest visible APR first."
        }
    }
    private func accountName(_ id: String) -> String { report.accounts.first(where: { $0.accountID == id })?.accountName ?? "Debt account" }
    private func friendlyMissingField(_ field: String) -> String { field == "debt_terms" ? "Debt Terms" : field.replacingOccurrences(of: "_", with: " ") }
    private func move(_ id: String, by offset: Int) { guard let index = customOrder.firstIndex(of: id) else { return }; let destination = index + offset; guard customOrder.indices.contains(destination) else { return }; customOrder.swapAt(index, destination) }
    private func calculate() async {
        guard let extraPayment else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let firstPayment = BudgetWorkspaceStore.dateString(Date())
            async let loaded = store.debtStrategyProjection(.init(firstPaymentOn: firstPayment, strategy: strategy, rollover: rollover, extraPaymentMinor: extraPayment, accountIDs: selectedAccountIDs, customOrder: strategy == "custom" ? customOrder : []))
            async let loadedBaseline = store.debtStrategyProjection(.init(firstPaymentOn: firstPayment, strategy: "avalanche", rollover: false, extraPaymentMinor: 0, accountIDs: selectedAccountIDs))
            let values = try await (loaded, loadedBaseline)
            guard !Task.isCancelled else { return }
            result = values.0; baseline = values.1; errorMessage = nil
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SpendingTrendsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APISpendingTrendsReport
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value }()

    var body: some View {
        Section("Spending Trends") {
            Picker("Trend by", selection: $store.spendingTrendDimension) {
                Text("Categories").tag("category"); Text("Groups").tag("group"); Text("Payees").tag("payee")
            }
            .pickerStyle(.segmented)
            .onChange(of: store.spendingTrendDimension) { _, _ in Task { await store.refresh() } }
            if report.series.isEmpty {
                ContentUnavailableView("No spending trend", systemImage: "chart.xyaxis.line", description: Text("Try a wider date range or different filters."))
            } else {
                Chart {
                    ForEach(report.series) { series in
                        ForEach(series.points) { point in
                            LineMark(x: .value("Month", dateFormatter.date(from: point.periodStart) ?? .distantPast), y: .value("Spending", point.spendingMinor))
                                .foregroundStyle(by: .value("Series", series.dimensionName))
                                .symbol(by: .value("Series", series.dimensionName))
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(report.series.first?.points.count ?? 1, 6))) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(minHeight: 240)
                .accessibilityIdentifier("spending-trends-chart")
                .accessibilityLabel("Spending trends by \(dimensionLabel.lowercased()) from \(report.startDate) through \(report.endDate)")
                .accessibilityValue("Total spending \(store.format(report.totalSpendingMinor)); \(report.series.count) ranked series. Exact values follow the chart.")
                ForEach(report.series) { series in destination(for: series) }
            }
        }
    }

    private var dimensionLabel: String { report.dimension == "payee" ? "Payees" : report.dimension == "group" ? "Groups" : "Categories" }

    @ViewBuilder private func destination(for series: APISpendingTrendSeries) -> some View {
        let months = max(series.points.count, 1)
        if report.dimension == "category", let category = store.spendingReport?.categories.first(where: { $0.categoryID == series.dimensionID }) {
            NavigationLink { LiveReportCategoryView(category: category) } label: { trendLabel(series, months: months) }
                .accessibilityIdentifier("spending-trend-category-\(series.dimensionID)")
        } else if report.dimension == "group" {
            NavigationLink { LiveReportGroupView(group: series.dimensionName) } label: { trendLabel(series, months: months) }
                .accessibilityIdentifier("spending-trend-group-\(series.dimensionID)")
        } else {
            NavigationLink { LiveReportTransactionsView(title: series.dimensionName, transactionIDs: series.transactionIDs, isTruncated: series.transactionIDsTruncated == true) } label: { trendLabel(series, months: months) }
                .accessibilityIdentifier("spending-trend-payee-\(series.dimensionID)")
        }
    }

    private func trendLabel(_ series: APISpendingTrendSeries, months: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(series.dimensionName, value: store.format(series.spendingMinor))
            Text("Monthly average \(store.format(series.spendingMinor / Int64(months)))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ResilienceInsightsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIResilienceReport

    var body: some View {
        Section("Financial Resilience") {
            LabeledContent("Cash buffer", value: store.format(report.cashBufferMinor))
            Text("Current balances in visible on-budget checking, savings, and cash accounts.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Scheduled income", value: store.format(report.scheduledIncomeMinor))
            LabeledContent("Scheduled outflows", value: store.format(report.scheduledOutflowsMinor))
            LabeledContent("Expected 30-day margin", value: store.format(report.expectedMarginMinor))
            LabeledContent("Lowest projected balance", value: store.format(report.lowestProjectedOnBudgetMinor))
            Text("Expected margin uses active scheduled income and outflows through \(report.through). It is forecast-only and does not change spendable money.").font(.caption).foregroundStyle(.secondary)
            ForEach(report.unavailableMetrics.keys.sorted(), id: \.self) { key in
                if let explanation = report.unavailableMetrics[key] {
                    Label(explanation, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("financial-resilience-insights")
    }
}

private struct HistoricalPlanPerformanceView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIPlanPerformanceReport
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value }()

    var body: some View {
        Section("Plan History") {
            if report.points.isEmpty {
                ContentUnavailableView("No planning history", systemImage: "chart.bar.xaxis", description: Text("Assignments and category activity will appear here over time."))
            } else {
                Chart {
                    ForEach(report.points) { point in
                        BarMark(x: .value("Month", dateFormatter.date(from: point.periodStart) ?? .distantPast), y: .value("Amount", point.assignedMinor))
                            .foregroundStyle(by: .value("Plan value", "Assigned"))
                        BarMark(x: .value("Month", dateFormatter.date(from: point.periodStart) ?? .distantPast), y: .value("Amount", point.spendingMinor))
                            .foregroundStyle(by: .value("Plan value", "Spent"))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(report.points.count, 6))) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(minHeight: 230)
                .accessibilityIdentifier("plan-performance-history-chart")
                .accessibilityLabel("Plan performance history from \(report.startDate) through \(report.endDate)")
                .accessibilityValue("\(report.points.count) monthly observations. Exact values follow the chart.")
                ForEach(report.points) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.periodStart).font(.headline)
                        LabeledContent("Assigned", value: store.format(point.assignedMinor))
                        LabeledContent("Spent", value: store.format(point.spendingMinor))
                        LabeledContent("Available", value: store.format(point.availableMinor))
                        LabeledContent("Unassigned", value: store.format(point.readyToAssignMinor))
                        if point.overspentMinor > 0 { LabeledContent("Overspent", value: store.format(point.overspentMinor)).foregroundStyle(.red) }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("plan-history-period-\(point.periodStart)")
                }
            }
        }
    }
}

private struct BudgetPerformanceInsightsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let summary: APIMonthSummary
    private var underfunded: [APICategoryMonth] { summary.categories.filter { ($0.underfundedMinor ?? 0) > 0 }.sorted { ($0.underfundedMinor ?? 0) > ($1.underfundedMinor ?? 0) } }
    private var overspent: [APICategoryMonth] { summary.categories.filter(\.isOverspent).sorted { $0.availableMinor < $1.availableMinor } }
    private var needed: Int64 { underfunded.reduce(0) { $0 + ($1.underfundedMinor ?? 0) } }

    var body: some View {
        Section("Plan Performance") {
            LabeledContent("Plan month", value: String(summary.month.prefix(7)))
            LabeledContent("Assigned", value: store.format(summary.totalAssignedMinor))
            LabeledContent("Ready to assign", value: store.format(summary.readyToAssignMinor))
            LabeledContent("Still needed for targets", value: store.format(needed))
            LabeledContent("Overspent", value: store.format(summary.totalOverspentMinor))
            if underfunded.isEmpty && overspent.isEmpty {
                Label("Targets funded and no overspending", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.healthy)
            } else {
                ForEach(Array((overspent + underfunded.filter { !$0.isOverspent }).prefix(8))) { row in
                    if let reportRow = store.spendingReport?.categories.first(where: { $0.categoryID == row.categoryID }) {
                        NavigationLink { LiveReportCategoryView(category: reportRow) } label: { performanceRow(row) }
                            .accessibilityIdentifier("plan-performance-category-\(row.categoryID)")
                    } else { performanceRow(row).accessibilityIdentifier("plan-performance-category-\(row.categoryID)") }
                }
                Text("Targets are planning guidance only. They do not create or move money.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func performanceRow(_ row: APICategoryMonth) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(row.name)
                Text(row.isOverspent ? "Overspent" : "Needs target funding").font(.caption).foregroundStyle(row.isOverspent ? Theme.danger : Theme.attention)
            }
            Spacer()
            Text(store.format(row.isOverspent ? abs(row.availableMinor) : (row.underfundedMinor ?? 0))).monospacedDigit()
        }
    }
}

private struct NetWorthReportView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APINetWorthReport
    @State private var selectedDate: Date?
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value }()

    var body: some View {
        Section("Net Worth") {
            if report.points.isEmpty {
                ContentUnavailableView("No account history", systemImage: "chart.line.uptrend.xyaxis", description: Text("Add an account balance or widen the date range."))
            } else {
                Chart {
                    ForEach(report.points) { point in
                        LineMark(x: .value("Date", dateFormatter.date(from: point.asOf) ?? .distantPast), y: .value("Amount", point.netWorthMinor), series: .value("Series", "Net Worth"))
                            .foregroundStyle(by: .value("Series", "Net Worth"))
                            .symbol(by: .value("Series", "Net Worth"))
                        LineMark(x: .value("Date", dateFormatter.date(from: point.asOf) ?? .distantPast), y: .value("Amount", point.assetsMinor), series: .value("Series", "Assets"))
                            .foregroundStyle(by: .value("Series", "Assets"))
                        LineMark(x: .value("Date", dateFormatter.date(from: point.asOf) ?? .distantPast), y: .value("Amount", point.liabilitiesMinor), series: .value("Series", "Liabilities"))
                            .foregroundStyle(by: .value("Series", "Liabilities"))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(report.points.count, 6))) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartXSelection(value: $selectedDate)
                .frame(minHeight: 240)
                .accessibilityIdentifier("net-worth-history-chart")
                .accessibilityLabel("Net worth history from \(report.startDate) through \(report.endDate)")
                .accessibilityValue("Assets \(store.format(report.assetsMinor)), liabilities \(store.format(report.liabilitiesMinor)), net worth \(store.format(report.netWorthMinor))")
            }
            LabeledContent("Assets", value: store.format(report.assetsMinor))
            LabeledContent("Liabilities", value: store.format(report.liabilitiesMinor))
            LabeledContent("Net worth", value: store.format(report.netWorthMinor)).fontWeight(.semibold)
            if let point = selectedPoint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected \(point.asOf)").font(.headline)
                    LabeledContent("Assets", value: store.format(point.assetsMinor))
                    LabeledContent("Liabilities", value: store.format(point.liabilitiesMinor))
                    LabeledContent("Net worth", value: store.format(point.netWorthMinor))
                }.accessibilityIdentifier("net-worth-selected-point")
            }
            ForEach(report.accounts) { row in
                if let account = store.accounts.first(where: { $0.id == row.accountID }) {
                    NavigationLink { LiveAccountRegisterView(initialAccount: account) } label: { LabeledContent(row.accountName, value: store.format(row.balanceMinor)) }
                        .accessibilityIdentifier("net-worth-account-\(account.id)")
                }
            }
        }
    }

    private var selectedPoint: APINetWorthPoint? {
        guard let selectedDate else { return nil }
        return report.points.min { lhs, rhs in
            abs((dateFormatter.date(from: lhs.asOf) ?? .distantPast).timeIntervalSince(selectedDate)) < abs((dateFormatter.date(from: rhs.asOf) ?? .distantPast).timeIntervalSince(selectedDate))
        }
    }
}

private struct DebtReportView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIDebtReport
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value }()

    var body: some View {
        Section("Debt") {
            if report.accounts.isEmpty {
                ContentUnavailableView("No debt accounts", systemImage: "checkmark.circle", description: Text("Credit cards and loans will appear here when visible."))
            } else {
                Chart(report.points) { point in
                    LineMark(x: .value("Date", dateFormatter.date(from: point.asOf) ?? .distantPast), y: .value("Debt", point.debtMinor))
                        .foregroundStyle(Theme.attention)
                        .symbol(.circle)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(report.points.count, 6))) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(minHeight: 220)
                .accessibilityIdentifier("debt-history-chart")
                .accessibilityLabel("Debt history from \(report.startDate) through \(report.endDate)")
                .accessibilityValue("Recorded debt as of \(report.endDate): \(store.format(report.debtMinor)), \(report.principalReductionMinor >= 0 ? "net debt decrease" : "net debt increase") \(store.format(abs(report.principalReductionMinor)))")
                LabeledContent("Opening debt", value: store.format(report.openingDebtMinor))
                LabeledContent("Debt as of \(report.endDate)", value: store.format(report.debtMinor)).fontWeight(.semibold)
                LabeledContent(report.principalReductionMinor >= 0 ? "Net debt decrease" : "Net debt increase", value: store.format(abs(report.principalReductionMinor)))
                Section("Recorded Interest") {
                    LabeledContent("Selected range", value: store.format(report.recordedInterestRangeMinor)).accessibilityIdentifier("recorded-interest-range")
                    LabeledContent("This month", value: store.format(report.recordedInterestMonthMinor))
                    LabeledContent("Year to date", value: store.format(report.recordedInterestYTDMinor))
                    LabeledContent("Trailing 12 months", value: store.format(report.recordedInterestTrailing12Minor))
                    if let started = report.interestTrackingStartedOn { Text("Recorded since \(started). Earlier interest may not be classified.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("recorded-interest-coverage") }
                    else { Text("No explicitly classified interest is recorded. Historical interest is not inferred from names or memos.").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(report.accounts) { row in
                    if let account = store.accounts.first(where: { $0.id == row.accountID }) {
                        NavigationLink { LiveAccountRegisterView(initialAccount: account) } label: { VStack(alignment: .leading) { LabeledContent(row.accountName, value: store.format(row.debtMinor)); if row.recordedInterestMinor != 0 { Text("Recorded interest \(store.format(row.recordedInterestMinor))").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("recorded-interest-account-\(account.id)") } } }
                            .accessibilityIdentifier("debt-account-\(account.id)")
                    }
                }
                Text("Recorded interest is posted classified history. Estimates and future payoff projections remain separate.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IncomeSpendingTrendsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let report: APIIncomeSpendingReport
    @State private var selectedDate: Date?
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
                .chartXSelection(value: $selectedDate)
                .frame(minHeight: 220)
                .accessibilityIdentifier("income-spending-trends-chart")
                .accessibilityLabel("Income and spending history from \(report.startDate) through \(report.endDate)")
                .accessibilityValue("Income \(store.format(report.incomeMinor)), spending \(store.format(report.spendingMinor)), net cash flow \(store.format(report.differenceMinor))")
            }
            LabeledContent("Income", value: store.format(report.incomeMinor))
            LabeledContent("Spending", value: store.format(report.spendingMinor))
            LabeledContent("Net cash flow", value: store.format(report.differenceMinor))
            if let rate = report.savingsRate { LabeledContent("Savings rate", value: rate.formatted(.percent.precision(.fractionLength(0)))) }
            if let period = selectedPeriod {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected \(period.periodStart) – \(period.periodEnd)").font(.headline)
                    LabeledContent("Income", value: store.format(period.incomeMinor))
                    LabeledContent("Spending", value: store.format(period.spendingMinor))
                    LabeledContent("Net cash flow", value: store.format(period.differenceMinor))
                    let ids = Array(Set(period.incomeTransactionIDs + period.spendingTransactionIDs)).sorted()
                    if !ids.isEmpty { NavigationLink("View contributing transactions") { LiveReportTransactionsView(title: "Cash Flow", transactionIDs: ids, isTruncated: period.incomeTransactionIDsTruncated == true || period.spendingTransactionIDsTruncated == true) } }
                }.accessibilityIdentifier("income-spending-selected-period")
            }
        }
    }

    private var selectedPeriod: APIIncomeSpendingPeriod? {
        guard let selectedDate else { return nil }
        return report.periods.min { lhs, rhs in
            abs((dateFormatter.date(from: lhs.periodStart) ?? .distantPast).timeIntervalSince(selectedDate)) < abs((dateFormatter.date(from: rhs.periodStart) ?? .distantPast).timeIntervalSince(selectedDate))
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
                .accessibilityLabel("Spending breakdown by \(mode.rawValue.lowercased())")
                .accessibilityValue("Total spending \(store.format(report.totalSpendingMinor)); \(slices.count) segments. Ranked values follow the chart.")
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

private struct LiveReportTransactionsView: View {
    @EnvironmentObject private var store: BudgetWorkspaceStore
    let title: String
    let transactionIDs: [String]
    var isTruncated = false
    private var transactions: [APITransaction] { store.transactions.filter { transactionIDs.contains($0.id) } }
    var body: some View {
        List {
            if isTruncated { Section { Label("Showing the first 500 contributing transactions. Report totals include all authorized activity.", systemImage: "info.circle") } }
            if transactions.isEmpty { ContentUnavailableView("No visible transactions", systemImage: "tray", description: Text("The contributing records are outside the currently hydrated authorized activity page.")) }
            else { ForEach(transactions) { LiveTransactionLink(transaction: $0) } }
        }.navigationTitle(title)
    }
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
    private var contributingIDsTruncated: Bool { reportLoaded ? (liveRow?.transactionIDsTruncated == true) : (category.transactionIDsTruncated == true) }
    var transactions: [APITransaction] { store.transactions.filter { contributingIDs.contains($0.id) } }
    var body: some View {
        List {
            Section {
                LabeledContent("Total", value: store.format(spendingMinor))
                LabeledContent("Transactions", value: "\(transactions.count)")
                LabeledContent("Average", value: store.format(transactions.isEmpty ? 0 : spendingMinor / Int64(transactions.count)))
                if contributingIDsTruncated { Label("Showing the first 500 contributors; the exact total includes all authorized activity.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
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
                if store.budget.effectivePermission == .owner {
                    Section("Household access") {
                        NavigationLink { HouseholdMemberLifecycleView(store: store) } label: {
                            Label("Members & Invitations", systemImage: "person.2.badge.gearshape")
                        }
                        .accessibilityIdentifier("household-members-lifecycle")
                        ForEach(store.householdMembers.filter { $0.role != "owner" && $0.isActive }) { member in
                            NavigationLink { LiveMemberAccessView(store: store, member: member) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.displayName)
                                    Text("Review what this member can see and change")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("member-access-\(member.userID)")
                        }
                        if store.householdMembers.allSatisfy({ $0.role == "owner" || !$0.isActive }) {
                            Text("No active household members to manage").foregroundStyle(.secondary)
                        }
                    }
                }
                if store.budget.can("manage_allowances") {
                    Section("Delegated budgets") {
                        NavigationLink { AllowanceManagementView(store: store) } label: {
                            Label("Allowances", systemImage: "calendar.badge.clock")
                        }
                        .accessibilityIdentifier("allowance-management")
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

private struct AllowanceManagementView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    @State private var showCreate = false
    private var active: [APIAllowancePlan] { store.allowances.filter(\.isActive) }
    private var paused: [APIAllowancePlan] { store.allowances.filter { !$0.isActive } }
    var body: some View {
        List {
            Section("Active") {
                ForEach(active) { plan in NavigationLink { AllowanceDetailView(store: store, planID: plan.id) } label: { row(plan) } }
                if active.isEmpty { Text("No active allowances").foregroundStyle(.secondary) }
            }
            if !paused.isEmpty {
                Section("Paused") {
                    ForEach(paused) { plan in NavigationLink { AllowanceDetailView(store: store, planID: plan.id) } label: { row(plan) } }
                    Text("Paused allowances do not move money and have no upcoming issuance.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Allowances")
        .toolbar { Button("New Allowance", systemImage: "plus") { showCreate = true } }
        .sheet(isPresented: $showCreate) { AllowanceCreateView(store: store) }
    }
    private func row(_ plan: APIAllowancePlan) -> some View { VStack(alignment: .leading, spacing: 3) { Text(plan.name); Text("\(store.format(plan.amountMinor)) · \(plan.isActive ? "next \(plan.nextIssueDate)" : "paused")").font(.caption).foregroundStyle(.secondary) } }
}

private struct AllowanceDetailView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    let planID: String
    @State private var history: [APIAllowanceIssuance] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    private var plan: APIAllowancePlan? { store.allowances.first { $0.id == planID } }
    var body: some View {
        List {
            if let plan {
                Section("Funding rule") {
                    LabeledContent("Amount", value: store.format(plan.amountMinor))
                    LabeledContent("Recipient", value: store.householdMembers.first(where: { $0.userID == plan.delegatedUserID })?.displayName ?? "Household member")
                    LabeledContent("Schedule", value: "Every \(plan.intervalCount) \(plan.recurrenceUnit)")
                    LabeledContent("Unused money", value: plan.rolloverPolicy == "rollover" ? "Carries forward" : "Returns before next issue")
                    LabeledContent("Status", value: plan.isActive ? "Active" : "Paused")
                    if plan.isActive { LabeledContent("Next issue", value: plan.nextIssueDate) }
                }
                Section("Destinations") { ForEach(Array(plan.splits.enumerated()), id: \.offset) { _, split in LabeledContent(store.categories.first(where: { $0.id == split.destinationCategoryID })?.name ?? "Category", value: store.format(split.amountMinor)) } }
                Section {
                    if plan.isActive && plan.nextIssueDate <= BudgetWorkspaceStore.dateString(Date()) { Button("Issue Now") { Task { await issue(plan) } }.disabled(isSaving || store.summary == nil) }
                    Button(plan.isActive ? "Pause Allowance" : "Reactivate Allowance", role: plan.isActive ? .destructive : nil) { Task { await setActive(plan, !plan.isActive) } }.disabled(isSaving)
                    Text("Creating or pausing a plan is money-neutral. Issue Now transfers existing category funds atomically through the allocation service.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("History") {
                    ForEach(history) { item in VStack(alignment: .leading) { Text(item.issuedOn); Text("Issued \(store.format(item.amountMinor))" + (item.reclaimedMinor > 0 ? " · returned \(store.format(item.reclaimedMinor))" : "")).font(.caption).foregroundStyle(.secondary) } }
                    if history.isEmpty { Text("No allowance has been issued yet").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(plan?.name ?? "Allowance")
        .task { await loadHistory() }
        .alert("Unable to update allowance", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }
    private func loadHistory() async { do { history = try await store.allowanceIssuances(id: planID) } catch { errorMessage = error.localizedDescription } }
    private func issue(_ plan: APIAllowancePlan) async { guard let version = store.summary?.allocationVersion else { return }; isSaving = true; defer { isSaving = false }; do { try await store.issueAllowance(id: plan.id, issueDate: plan.nextIssueDate, expectedVersion: version); await loadHistory() } catch { errorMessage = error.localizedDescription } }
    private func setActive(_ plan: APIAllowancePlan, _ active: Bool) async { isSaving = true; defer { isSaving = false }; do { try await store.setAllowanceActive(id: plan.id, active: active) } catch { errorMessage = error.localizedDescription } }
}

private struct AllowanceCreateView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var memberID = ""; @State private var sourceID = ""; @State private var destinationID = ""; @State private var name = ""; @State private var amount = ""; @State private var nextDate = Date(); @State private var recurrence = "week"; @State private var interval = 1; @State private var rollover = "rollover"; @State private var isSaving = false; @State private var errorMessage: String?
    private var members: [APIHouseholdMember] { store.householdMembers.filter { $0.role != "owner" && $0.isActive } }
    private var destinations: [APICategory] { store.categories.filter { $0.delegatedUserID == memberID && !$0.isArchived } }
    private var sources: [APICategory] { store.categories.filter { !$0.isArchived && $0.id != destinationID && $0.delegatedUserID == nil } }
    private var parsed: Int64? { guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: store.budget.currencyCode), value > 0 else { return nil }; return value }
    var body: some View { NavigationStack { Form {
        Picker("Recipient", selection: $memberID) { Text("Select member").tag(""); ForEach(members) { Text($0.displayName).tag($0.userID) } }
        TextField("Allowance name", text: $name)
        CurrencyAmountField("Amount", text: $amount, currencyCode: store.budget.currencyCode)
        Picker("Fund from", selection: $sourceID) { Text("Select category").tag(""); ForEach(sources) { Text($0.name).tag($0.id) } }
        Picker("Deliver to", selection: $destinationID) { Text("Select delegated category").tag(""); ForEach(destinations) { Text($0.name).tag($0.id) } }
        DatePicker("First issue", selection: $nextDate, displayedComponents: .date)
        Picker("Repeats", selection: $recurrence) { Text("Weekly").tag("week"); Text("Monthly").tag("month") }
        Stepper("Every \(interval) \(recurrence == "week" ? "week(s)" : "month(s)")", value: $interval, in: 1...52)
        Picker("Unused money", selection: $rollover) { Text("Carry forward").tag("rollover"); Text("Return before next issue").tag("use_it_or_lose_it") }
        Section { Text("Saving schedules the rule only. Money moves only when an authorized person issues a due allowance.").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("New Allowance").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberID.isEmpty || sourceID.isEmpty || destinationID.isEmpty || parsed == nil || isSaving) } }.onAppear { memberID = members.first?.userID ?? ""; selectDefaults() }.onChange(of: memberID) { _, _ in destinationID = destinations.first?.id ?? ""; selectDefaults() }.alert("Unable to create allowance", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } } }
    private func selectDefaults() { if destinationID.isEmpty { destinationID = destinations.first?.id ?? "" }; if sourceID.isEmpty || sourceID == destinationID { sourceID = sources.first?.id ?? "" } }
    private func save() async { guard let parsed else { return }; isSaving = true; defer { isSaving = false }; do { try await store.createAllowance(.init(delegatedUserID: memberID, sourceCategoryID: sourceID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), amountMinor: parsed, nextIssueDate: BudgetWorkspaceStore.dateString(nextDate), recurrenceUnit: recurrence, intervalCount: interval, rolloverPolicy: rollover, splits: [.init(destinationCategoryID: destinationID, amountMinor: parsed)])); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct HouseholdMemberLifecycleView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    @State private var invitations: [APIInvitationSummary] = []
    @State private var events: [APIHouseholdAccessEvent] = []
    @State private var showInvite = false
    @State private var secret: APIInvitationSecret?
    @State private var removing: APIHouseholdMember?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Members") {
                ForEach(store.householdMembers.filter { $0.role != "owner" }) { member in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(member.displayName); Spacer(); Text(member.isActive ? "Active" : "Removed").foregroundStyle(member.isActive ? Theme.healthy : .secondary) }
                        Text(member.email).font(.caption).foregroundStyle(.secondary)
                        if member.isActive {
                            HStack {
                                NavigationLink("Edit Access") { LiveMemberAccessView(store: store, member: member) }
                                Spacer()
                                Button("Remove", role: .destructive) { removing = member }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(member.displayName) from household")
                            }
                        } else {
                            Button("Invite to Rejoin") { secret = nil; showInvite = true }
                                .accessibilityHint("Creates a new invitation; preserved access is restored only after acceptance")
                        }
                    }
                }
                if store.householdMembers.allSatisfy({ $0.role == "owner" }) { Text("No other household members").foregroundStyle(.secondary) }
            }
            Section("Invitations") {
                ForEach(invitations) { invitation in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(invitation.email); Spacer(); Text(invitation.status.capitalized).foregroundStyle(invitation.status == "pending" ? Theme.attention : .secondary) }
                        Text("\(invitation.role.capitalized) · invited by \(invitation.createdByDisplayName)").font(.caption).foregroundStyle(.secondary)
                        if invitation.status == "pending" || invitation.status == "expired" {
                            HStack {
                                Button("Resend") { Task { await resend(invitation) } }.buttonStyle(.borderless)
                                Spacer()
                                if invitation.status == "pending" { Button("Cancel", role: .destructive) { Task { await cancel(invitation) } }.buttonStyle(.borderless) }
                            }
                        }
                    }
                }
                if invitations.isEmpty && !isLoading { Text("No invitations").foregroundStyle(.secondary) }
            }
            if !events.isEmpty {
                Section("Recent access activity") {
                    ForEach(events.prefix(20)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(eventTitle(event))
                            Text("\(event.actorDisplayName) · \(event.createdAt)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Members")
        .toolbar { Button("Invite", systemImage: "person.badge.plus") { showInvite = true }.accessibilityIdentifier("invite-household-member") }
        .task { await load() }
        .sheet(isPresented: $showInvite) { HouseholdInvitationCreateView(store: store, recoveredSecret: $secret, onCreated: load) }
        .sheet(item: $secret) { value in NavigationStack { Form { Section("Invitation code") { Text(value.invitationToken).textSelection(.enabled).accessibilityIdentifier("invitation-code"); Button("Copy Code") { UIPasteboard.general.string = value.invitationToken } }; Section { Text("Send this code privately to \(value.email). It expires in seven days and can be used once.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Invitation Ready").toolbar { Button("Done") { secret = nil } } } }
        .confirmationDialog("Remove \(removing?.displayName ?? "member")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Member", role: .destructive) { if let member = removing { Task { await remove(member) } } }
        } message: { Text("Their historical activity remains. Current access stops immediately and can be recovered only through a new invitation.") }
        .overlay { if isLoading { ProgressView() } }
        .alert("Unable to update household", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func eventTitle(_ event: APIHouseholdAccessEvent) -> String {
        switch event.eventType {
        case "invitation_created": return "Invitation created for \(event.detail ?? "member")"
        case "invitation_resent": return "Invitation resent to \(event.detail ?? "member")"
        case "invitation_canceled": return "Invitation canceled for \(event.detail ?? "member")"
        case "invitation_accepted": return "\(event.subjectDisplayName ?? "Member") joined"
        case "member_removed": return "\(event.subjectDisplayName ?? "Member") removed"
        case "member_left": return "\(event.subjectDisplayName ?? "Member") left"
        default: return event.eventType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private func load() async { isLoading = true; defer { isLoading = false }; do { async let invitationRows = store.householdInvitations(); async let eventRows = store.householdAccessEvents(); invitations = try await invitationRows; events = try await eventRows; errorMessage = nil } catch { errorMessage = error.localizedDescription } }
    private func resend(_ invitation: APIInvitationSummary) async { do { secret = try await store.resendHouseholdInvitation(id: invitation.id); await load() } catch { errorMessage = error.localizedDescription } }
    private func cancel(_ invitation: APIInvitationSummary) async { do { try await store.cancelHouseholdInvitation(id: invitation.id); await load() } catch { errorMessage = error.localizedDescription } }
    private func remove(_ member: APIHouseholdMember) async { removing = nil; do { try await store.removeHouseholdMember(userID: member.userID); await load() } catch { errorMessage = error.localizedDescription } }
}

private struct HouseholdInvitationCreateView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    @Binding var recoveredSecret: APIInvitationSecret?
    let onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "adult"
    @State private var isSaving = false
    @State private var errorMessage: String?
    var body: some View { NavigationStack { Form { TextField("Email", text: $email).textContentType(.emailAddress).textInputAutocapitalization(.never).keyboardType(.emailAddress); Picker("Household role", selection: $role) { Text("Adult").tag("adult"); Text("Child").tag("child") }; Section { Text("An invitation creates membership only after the recipient accepts its private code. Budget access is then configured separately.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Invite Member").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(isSaving || !email.contains("@")) } }.alert("Unable to create invitation", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") } } }
    private func create() async { isSaving = true; defer { isSaving = false }; do { let value = try await store.createHouseholdInvitation(.init(email: email, role: role)); dismiss(); await onCreated(); recoveredSecret = value } catch { errorMessage = error.localizedDescription } }
}

private enum MemberAccessPreset: String, CaseIterable, Identifiable {
    case view = "View Only"
    case limited = "Limited Access"
    case full = "Full Access"
    case custom = "Custom"
    var id: String { rawValue }

    var capabilities: Set<String> {
        switch self {
        case .view: return ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances"]
        case .limited: return ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances", "create_transaction", "edit_transaction", "request_money"]
        case .full: return ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances", "view_allocation_history", "create_transaction", "edit_transaction", "delete_transaction", "assign_money", "move_money", "reconcile_account", "manage_budget_structure", "manage_payees", "manage_planning", "manage_allowances", "approve_request", "request_money", "export_data"]
        case .custom: return []
        }
    }
}

private struct MemberCapability: Identifiable {
    let id: String
    let title: String
    let explanation: String
}

private struct LiveMemberAccessView: View {
    @ObservedObject var store: BudgetWorkspaceStore
    let member: APIHouseholdMember
    @State private var profile: APIAccessProfile?
    @State private var preset: MemberAccessPreset = .view
    @State private var capabilities: Set<String> = []
    @State private var restrictAccounts = false
    @State private var accountIDs: Set<String> = []
    @State private var restrictCategories = false
    @State private var categoryIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var didSave = false
    @State private var errorMessage: String?

    private let visibility = [
        MemberCapability(id: "view_budget", title: "Open this budget", explanation: "Access the budget workspace"),
        MemberCapability(id: "view_accounts", title: "Account list", explanation: "See permitted account names"),
        MemberCapability(id: "view_account_balances", title: "Account balances", explanation: "See balances for permitted accounts"),
        MemberCapability(id: "view_categories", title: "Plan and categories", explanation: "See permitted categories and their plan"),
        MemberCapability(id: "view_transactions", title: "Activity", explanation: "See transactions within permitted accounts and categories"),
        MemberCapability(id: "view_reports", title: "Insights", explanation: "See privacy-filtered reports"),
        MemberCapability(id: "view_allocation_history", title: "Allocation history", explanation: "See money assignment history")
    ]
    private let transactions = [
        MemberCapability(id: "create_transaction", title: "Create transactions", explanation: "Add activity in permitted accounts and categories"),
        MemberCapability(id: "edit_transaction", title: "Edit transactions", explanation: "Edit activity and manage its attachments"),
        MemberCapability(id: "delete_transaction", title: "Delete transactions", explanation: "Remove eligible activity")
    ]
    private let planning = [
        MemberCapability(id: "assign_money", title: "Assign money", explanation: "Change category assignments"),
        MemberCapability(id: "move_money", title: "Move money", explanation: "Move available funds between permitted categories"),
        MemberCapability(id: "manage_planning", title: "Manage planning tools", explanation: "Manage targets, funding, and scheduled transactions"),
        MemberCapability(id: "manage_own_categories", title: "Manage own categories", explanation: "Organize categories delegated to this member")
    ]
    private let administration = [
        MemberCapability(id: "manage_budget_structure", title: "Manage budget structure", explanation: "Create and edit accounts, groups, and categories"),
        MemberCapability(id: "reconcile_account", title: "Reconcile accounts", explanation: "Finalize cleared balances"),
        MemberCapability(id: "manage_payees", title: "Manage payees", explanation: "Rename, merge, and archive payees"),
        MemberCapability(id: "manage_allowances", title: "Manage delegated budgets", explanation: "Set household funding authority"),
        MemberCapability(id: "approve_request", title: "Approve requests", explanation: "Approve or deny money requests"),
        MemberCapability(id: "request_money", title: "Request money", explanation: "Submit funding requests"),
        MemberCapability(id: "export_data", title: "Export reports", explanation: "Export authorized reporting data")
    ]

    var body: some View {
        Group {
            if isLoading { ProgressView("Loading access…") }
            else if profile == nil { ContentUnavailableView("Access unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage ?? "Unable to load this member's access.")) }
            else { form }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar { if profile != nil { Button(didSave ? "Saved" : "Save") { Task { await save() } }.disabled(isSaving || (restrictAccounts && accountIDs.isEmpty) || (restrictCategories && categoryIDs.isEmpty)) } }
        .alert("Unable to update access", isPresented: Binding(get: { errorMessage != nil && profile != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        .accessibilityIdentifier("member-access-screen")
    }

    private var form: some View {
        Form {
            if didSave { Section { Label("Access saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("member-access-saved") } }
            Section("Access level") {
                Picker("Preset", selection: $preset) { ForEach(MemberAccessPreset.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: preset) { _, value in if value != .custom { capabilities = value.capabilities } }
                    .accessibilityIdentifier("member-access-preset")
                if preset == .full { Text("Full budget access does not transfer household ownership.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Account visibility") {
                Toggle("Only selected accounts", isOn: $restrictAccounts).accessibilityIdentifier("member-access-restrict-accounts")
                if restrictAccounts { ForEach(store.accounts.filter { !$0.isClosed }) { account in selectionToggle(account.name, id: account.id, values: $accountIDs) } }
                if restrictAccounts && accountIDs.isEmpty { Text("Select at least one account.").font(.footnote).foregroundStyle(.red) }
                Text("Transfers require transaction permission and access to both accounts.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Category visibility") {
                Toggle("Only selected categories", isOn: $restrictCategories)
                if restrictCategories { ForEach(store.categories.filter { !$0.isArchived }) { category in selectionToggle(category.name, id: category.id, values: $categoryIDs) } }
                if restrictCategories && categoryIDs.isEmpty { Text("Select at least one category.").font(.footnote).foregroundStyle(.red) }
            }
            capabilitySection("Visibility", visibility)
            capabilitySection("Transactions", transactions)
            capabilitySection("Planning", planning)
            capabilitySection("Accounts, requests, and organization", administration)
            if let profile, let actor = profile.updatedByDisplayName, let date = profile.updatedAt {
                Section("Last change") { LabeledContent("Changed by", value: actor); LabeledContent("Date", value: date) }
            }
        }
    }

    private func capabilitySection(_ title: String, _ items: [MemberCapability]) -> some View {
        Section(title) { ForEach(items) { item in Toggle(isOn: capabilityBinding(item.id)) { VStack(alignment: .leading) { Text(item.title); Text(item.explanation).font(.caption).foregroundStyle(.secondary) } } } }
    }
    private func capabilityBinding(_ name: String) -> Binding<Bool> { Binding(get: { capabilities.contains(name) }, set: { enabled in if enabled { capabilities.insert(name) } else { capabilities.remove(name) }; preset = matchingPreset() }) }
    private func selectionToggle(_ title: String, id: String, values: Binding<Set<String>>) -> some View { Toggle(title, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { if $0 { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) } })) }
    private func matchingPreset() -> MemberAccessPreset { MemberAccessPreset.allCases.first(where: { $0 != .custom && $0.capabilities == capabilities }) ?? .custom }
    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { let value = try await store.accessProfile(userID: member.userID); apply(value); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func apply(_ value: APIAccessProfile) {
        profile = value; capabilities = Set(value.capabilities); preset = matchingPreset()
        restrictAccounts = value.restrictAccounts; accountIDs = Set(value.accountIDs)
        restrictCategories = value.restrictCategories; categoryIDs = Set(value.categoryIDs)
    }
    private func save() async {
        guard let profile else { return }; isSaving = true; defer { isSaving = false }
        do {
            let value = APIAccessProfileUpsert(capabilities: capabilities.sorted(), restrictAccounts: restrictAccounts, accountIDs: accountIDs.sorted(), restrictCategories: restrictCategories, categoryIDs: categoryIDs.sorted(), expectedVersion: profile.version)
            apply(try await store.updateAccessProfile(userID: member.userID, value: value)); errorMessage = nil; didSave = true
        } catch { errorMessage = error.localizedDescription }
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
    @State private var payee: String; @State private var payeeID: String?; @State private var amount: String; @State private var accountID: String; @State private var categoryID: String; @State private var memo: String; @State private var financialClassification: String; @State private var cleared: Bool; @State private var date: Date; @State private var isInflow: Bool; @State private var isSplit: Bool; @State private var splitRows: [WorkspaceSplitDraft]; @State private var flag: String; @State private var tags: String
    @State private var selectedPayeeName: String; @State private var showPayeeSelector = false
    @State private var isSaving = false; @State private var errorMessage: String?
    init(budget: APIBudget, transaction: APITransaction, accounts: [APIAccount], categories: [APICategory], onSaved: @escaping () async -> Void) {
        self.budget=budget; self.transaction=transaction; self.accounts=accounts; self.categories=categories; self.onSaved=onSaved
        _payee=State(initialValue:transaction.payeeName); _payeeID=State(initialValue:transaction.payeeID); _selectedPayeeName=State(initialValue:transaction.payeeID == nil ? "" : transaction.payeeName); _amount=State(initialValue:CurrencyText.editable(abs(transaction.amountMinor),currencyCode:budget.currencyCode)); _accountID=State(initialValue:transaction.accountID); _categoryID=State(initialValue:transaction.categoryID ?? ""); _memo=State(initialValue:transaction.memo); _financialClassification=State(initialValue:transaction.financialClassification ?? ""); _cleared=State(initialValue:transaction.isCleared); _date=State(initialValue:Self.parseDate(transaction.occurredOn)); _isInflow=State(initialValue:transaction.amountMinor > 0); _isSplit=State(initialValue:!transaction.splits.isEmpty); _splitRows=State(initialValue:transaction.splits.map { WorkspaceSplitDraft(categoryID:$0.categoryID,amount:CurrencyText.editable(abs($0.amountMinor),currencyCode:budget.currencyCode),memo:$0.memo,financialClassification:$0.financialClassification ?? "") }); _flag=State(initialValue:transaction.flag ?? ""); _tags=State(initialValue:(transaction.tags ?? []).joined(separator:", "))
    }
    var body: some View { NavigationStack { Form {
        TextField("Payee",text:$payee).onChange(of:payee){_,value in if payeeID != nil && selectedPayeeName != value { payeeID=nil;selectedPayeeName="" }}; Button("Choose saved payee",systemImage:"person.text.rectangle"){showPayeeSelector=true}.accessibilityIdentifier("saved-payee-menu"); CurrencyAmountField("Amount", text:$amount, currencyCode:budget.currencyCode); Toggle("Income / inflow",isOn:$isInflow); Picker("Account",selection:$accountID){ForEach(accounts.filter{!$0.isClosed}){Text($0.name).tag($0.id)}}; if selectedAccountIsDebt && !isInflow && !isSplit { Picker("Classification",selection:$financialClassification){Text("Ordinary transaction").tag("");Text("Interest charge").tag("interest_charge")} }; DatePicker("Date",selection:$date,displayedComponents:.date); Toggle("Split across categories",isOn:$isSplit).disabled(isInflow)
        if isSplit { Section("Splits") { ForEach($splitRows) { $row in Picker("Category",selection:$row.categoryID){Text("Select").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}};CurrencyAmountField("Split amount", text:$row.amount, currencyCode:budget.currencyCode, allowsZero:true);TextField("Split memo",text:$row.memo);if selectedAccountIsDebt{Picker("Split classification",selection:$row.financialClassification){Text("Ordinary").tag("");Text("Interest charge").tag("interest_charge")}} }; Button("Add split",systemImage:"plus"){splitRows.append(.init())}; if let remaining { LabeledContent("Remaining",value:CurrencyText.editable(remaining,currencyCode:budget.currencyCode)).foregroundStyle(remaining == 0 ? Color.secondary : Color.red) } } } else if !isInflow { Picker("Category",selection:$categoryID){Text("Uncategorized").tag("");ForEach(categories.filter{!$0.isArchived}){Text($0.name).tag($0.id)}} }
        TextField("Memo",text:$memo); Picker("Flag",selection:$flag){Text("None").tag("");Text("Red").tag("red");Text("Orange").tag("orange");Text("Yellow").tag("yellow");Text("Green").tag("green");Text("Blue").tag("blue");Text("Purple").tag("purple")}; TextField("Tags (comma separated)",text:$tags);Text("Manage attachments from transaction detail.").font(.footnote).foregroundStyle(.secondary);Toggle("Cleared",isOn:$cleared)
    }.navigationTitle("Edit Transaction").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(isSaving || parsed == nil || !splitsValid)} }.alert("Unable to save",isPresented:Binding(get:{errorMessage != nil},set:{if !$0{errorMessage=nil}})){Button("OK",role:.cancel){}}message:{Text(errorMessage ?? "Unknown error")}.onChange(of:accountID){_,_ in clearInvalidClassification()}.onChange(of:isInflow){_,_ in clearInvalidClassification()}.sheet(isPresented:$showPayeeSelector){PayeeSearchSelectionView{item in payeeID=item.id;payee=item.displayName;selectedPayeeName=item.displayName;if categoryID.isEmpty,let suggested=item.defaultCategoryID{categoryID=suggested}}} } }
    private var parsed:Int64?{guard let value=CurrencyText.parseMinorUnits(amount,currencyCode:budget.currencyCode),value>0 else{return nil};return isInflow ? value : -value}
    private var parsedSplits:[TransactionSplitOperation]?{guard isSplit else{return []};var values:[TransactionSplitOperation]=[];for row in splitRows{guard !row.categoryID.isEmpty,let value=CurrencyText.parseMinorUnits(row.amount,currencyCode:budget.currencyCode),value>=0 else{return nil};values.append(.init(categoryID:row.categoryID,amountMinor:-value,memo:row.memo,financialClassification:row.financialClassification.isEmpty ? nil:row.financialClassification))};return values}
    private var remaining:Int64?{guard let parsed,let parsedSplits else{return nil};return parsed - parsedSplits.reduce(0){$0+$1.amountMinor}}
    private var splitsValid:Bool{!isSplit || (parsedSplits?.count ?? 0)>=2 && remaining==0}
    private func save() async { guard let parsed,let parsedSplits else{return};isSaving=true;defer{isSaving=false};do{try await workspace.updateTransaction(id:transaction.id,operation:RecordTransactionOperation(accountID:accountID,categoryID:isSplit || isInflow || categoryID.isEmpty ? nil:categoryID,amountMinor:parsed,occurredOn:BudgetWorkspaceStore.dateString(date),payeeName:payee,payeeID:payeeID,memo:memo,financialClassification:financialClassification.isEmpty || isSplit ? nil:financialClassification,isCleared:cleared,splits:parsedSplits,flag:flag.isEmpty ? nil:flag,tags:commaValues(tags),attachmentMetadata:transaction.attachmentMetadata ?? []));dismiss()}catch{errorMessage=error.localizedDescription} }
    private var selectedAccountIsDebt:Bool{guard let type=accounts.first(where:{$0.id==accountID})?.accountType else{return false};return type=="credit" || type=="loan"}
    private func clearInvalidClassification(){if !selectedAccountIsDebt || isInflow {financialClassification="";for index in splitRows.indices{splitRows[index].financialClassification=""}}}
    private func commaValues(_ value:String)->[String]{value.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}}
    private static func parseDate(_ value:String)->Date{let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd";return formatter.date(from:value) ?? Date()}
}

private struct WorkspaceSplitDraft:Identifiable{let id=UUID();var categoryID="";var amount="";var memo="";var financialClassification=""}
