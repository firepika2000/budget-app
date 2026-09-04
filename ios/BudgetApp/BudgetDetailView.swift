import BudgetAPI
import SwiftUI

struct BudgetDetailView: View {
    let budget: APIBudget
    @EnvironmentObject private var session: AppSession
    @State private var summary: APIMonthSummary?
    @State private var accounts: [APIAccount] = []
    @State private var categories: [APICategory] = []
    @State private var categoryGroups: [APICategoryGroup] = []
    @State private var transactions: [APITransaction] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingTransactionEntry = false
    @State private var editingCategory: APICategoryMonth?
    @State private var showingAccountCreation = false
    @State private var showingCategoryCreation = false
    @State private var showingAllocationTransfer = false

    var body: some View {
        List {
            monthSection
            planSection
            accountsSection
            transactionsSection
        }
        .navigationTitle(budget.name)
        .toolbar {
            if budget.effectivePermission.canContribute {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingTransactionEntry = true } label: {
                        Label("New transaction", systemImage: "plus")
                    }
                    .disabled(accounts.filter { !$0.isClosed }.isEmpty)
                }
            }
            if budget.effectivePermission.canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add account", systemImage: "wallet.pass") { showingAccountCreation = true }
                        Button("Add category", systemImage: "folder.badge.plus") { showingCategoryCreation = true }
                        Button("Move money", systemImage: "arrow.left.arrow.right") { showingAllocationTransfer = true }
                    } label: {
                        Label("Budget setup", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .alert("Unable to load budget", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showingTransactionEntry) {
            if let serverURL = session.serverURL, let token = session.token {
                TransactionEntryView(
                    budget: budget,
                    accounts: accounts,
                    categories: categories,
                    serverURL: serverURL,
                    token: token,
                    onSaved: load
                )
            }
        }
        .sheet(item: $editingCategory) { category in
            if let serverURL = session.serverURL, let token = session.token {
                AssignmentEditView(
                    budget: budget,
                    category: category,
                    month: currentMonth(),
                    expectedAllocationVersion: summary?.allocationVersion ?? budget.allocationVersion,
                    serverURL: serverURL,
                    token: token,
                    onSaved: load
                )
            }
        }
        .sheet(isPresented: $showingAccountCreation) {
            if let serverURL = session.serverURL, let token = session.token {
                AccountCreationView(budget: budget, serverURL: serverURL, token: token, onSaved: load)
            }
        }
        .sheet(isPresented: $showingCategoryCreation) {
            if let serverURL = session.serverURL, let token = session.token {
                CategoryCreationView(
                    budget: budget,
                    groups: categoryGroups,
                    serverURL: serverURL,
                    token: token,
                    onSaved: load
                )
            }
        }
        .sheet(isPresented: $showingAllocationTransfer) {
            if let serverURL = session.serverURL, let token = session.token, let summary {
                AllocationTransferView(
                    budget: budget,
                    categories: summary.categories,
                    expectedAllocationVersion: summary.allocationVersion,
                    serverURL: serverURL,
                    token: token,
                    onSaved: load
                )
            }
        }
    }

    @ViewBuilder
    private var monthSection: some View {
        if let summary {
            Section("This month") {
                moneyRow("Ready to assign", summary.readyToAssignMinor, emphasized: true)
                moneyRow("Assigned", summary.totalAssignedMinor)
                if summary.totalOverspentMinor > 0 {
                    moneyRow("Overspent", -summary.totalOverspentMinor, color: .red)
                }
            }
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if let summary {
            Section("Plan") {
                ForEach(summary.categories) { category in
                    CategoryMonthRow(category: category, formatted: format(category.availableMinor), assigned: format(category.assignedMinor), activity: format(category.activityMinor))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if budget.effectivePermission.canManage {
                                editingCategory = category
                            }
                        }
                }
            }
        }
    }

    private var accountsSection: some View {
        Section("Accounts") {
            ForEach(accounts) { account in
                HStack {
                    Image(systemName: icon(for: account.accountType)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(account.name)
                        Text(account.accountType.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if account.isClosed {
                        Spacer()
                        Text("Closed").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transactionsSection: some View {
        Section("Recent transactions") {
            ForEach(Array(transactions.prefix(20))) { transaction in
                HStack {
                    VStack(alignment: .leading) {
                        Text(transaction.payeeName.isEmpty ? "No payee" : transaction.payeeName)
                        Text(transaction.occurredOn).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(format(transaction.amountMinor))
                        .foregroundStyle(transaction.amountMinor < 0 ? Color.primary : Color.green)
                }
            }
        }
    }

    @ViewBuilder
    private func moneyRow(
        _ label: String,
        _ value: Int64,
        emphasized: Bool = false,
        color: Color = .primary
    ) -> some View {
        HStack {
            Text(label).fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            Text(format(value)).fontWeight(emphasized ? .semibold : .regular).foregroundStyle(color)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await session.refreshIfNeeded()
            guard let serverURL = session.serverURL, let token = session.token else { return }
            let client = try APIClient(baseURL: serverURL)
            async let loadedAccounts = client.accounts(budgetID: budget.id, token: token)
            async let loadedTransactions = client.transactions(budgetID: budget.id, token: token)
            async let loadedCategories = client.categories(budgetID: budget.id, token: token)
            async let loadedCategoryGroups = client.categoryGroups(budgetID: budget.id, token: token)
            async let loadedSummary = client.monthSummary(
                budgetID: budget.id,
                month: currentMonth(),
                token: token
            )
            (accounts, transactions, categories, categoryGroups, summary) = try await (
                loadedAccounts,
                loadedTransactions,
                loadedCategories,
                loadedCategoryGroups,
                loadedSummary
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentMonth() -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d-01", components.year ?? 2000, components.month ?? 1)
    }

    private func format(_ minorUnits: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = budget.currencyCode
        let digits = formatter.maximumFractionDigits
        let divisor = pow(10.0, Double(digits))
        return formatter.string(from: NSNumber(value: Double(minorUnits) / divisor)) ?? "\(minorUnits)"
    }

    private func icon(for accountType: String) -> String {
        switch accountType {
        case "credit": "creditcard"
        case "cash": "banknote"
        case "savings": "building.columns"
        default: "wallet.pass"
        }
    }
}

private struct CategoryMonthRow: View {
    let category: APICategoryMonth
    let formatted: String
    let assigned: String
    let activity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(category.name)
                Spacer()
                Text(formatted).foregroundStyle(category.isOverspent ? Color.red : Color.primary)
            }
            HStack {
                Text("Assigned \(assigned)")
                Spacer()
                Text("Activity \(activity)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
