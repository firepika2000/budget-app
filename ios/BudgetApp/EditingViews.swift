import BudgetAPI
import SwiftUI

struct TransactionEntryView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let accounts: [APIAccount]
    let categories: [APICategory]
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var categoryID: String?
    @State private var payee = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var date = Date()
    @State private var isInflow = false
    @State private var isCleared = false
    @State private var isSplit = false
    @State private var flag = ""
    @State private var tags = ""
    @State private var attachments = ""
    @State private var splitRows = [SplitDraft(), SplitDraft()]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(budget: APIBudget, accounts: [APIAccount], categories: [APICategory], serverURL: URL, token: String, initialAccountID: String? = nil, onSaved: @escaping () async -> Void) {
        self.budget = budget
        self.accounts = accounts
        self.categories = categories
        self.serverURL = serverURL
        self.token = token
        self.onSaved = onSaved
        _accountID = State(initialValue: initialAccountID ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Account", selection: $accountID) {
                    ForEach(accounts.filter { !$0.isClosed }) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                TextField("Payee", text: $payee)
                CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode)
                Toggle("Income / inflow", isOn: $isInflow)
                Toggle("Split across categories", isOn: $isSplit)
                    .disabled(isInflow)
                if isSplit {
                    Section("Splits") {
                        ForEach($splitRows) { $row in
                            Picker("Category", selection: $row.categoryID) {
                                Text("Select category").tag("")
                                ForEach(categories.filter { !$0.isArchived }) { category in
                                    Text(category.name).tag(category.id)
                                }
                            }
                            CurrencyAmountField("Split amount", text: $row.amount, currencyCode: budget.currencyCode, allowsZero: true)
                            TextField("Split memo", text: $row.memo)
                        }
                        Button("Add another split", systemImage: "plus") { splitRows.append(SplitDraft()) }
                        if let remainingSplitAmount {
                            LabeledContent("Remaining", value: CurrencyText.editable(remainingSplitAmount, currencyCode: budget.currencyCode))
                                .foregroundStyle(remainingSplitAmount == 0 ? Color.secondary : Color.red)
                        }
                    }
                } else {
                    Picker("Category", selection: $categoryID) {
                        Text(isInflow ? "Ready to assign" : "Uncategorized")
                            .tag(nil as String?)
                        ForEach(categories.filter { !$0.isArchived }) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Memo", text: $memo)
                Picker("Flag", selection: $flag) { Text("None").tag(""); Text("Red").tag("red"); Text("Orange").tag("orange"); Text("Yellow").tag("yellow"); Text("Green").tag("green"); Text("Blue").tag("blue"); Text("Purple").tag("purple") }
                TextField("Tags (comma separated)", text: $tags)
                TextField("Attachment names (metadata only)", text: $attachments)
                Toggle("Cleared", isOn: $isCleared)
            }
            .navigationTitle("New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || accountID.isEmpty || parsedAmount == nil || !splitsAreValid)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .onAppear {
                if accountID.isEmpty { accountID = accounts.first(where: { !$0.isClosed })?.id ?? "" }
            }
            .onChange(of: isInflow) { _, inflow in
                if inflow {
                    categoryID = nil
                    isSplit = false
                }
            }
        }
    }

    private var parsedAmount: Int64? {
        guard let magnitude = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode),
              magnitude >= 0 else { return nil }
        return isInflow ? magnitude : -magnitude
    }

    private var parsedSplits: [APITransactionSplitCreate]? {
        guard isSplit else { return [] }
        var result: [APITransactionSplitCreate] = []
        for row in splitRows {
            guard !row.categoryID.isEmpty,
                  let amount = CurrencyText.parseMinorUnits(row.amount, currencyCode: budget.currencyCode),
                  amount >= 0 else { return nil }
            result.append(APITransactionSplitCreate(categoryID: row.categoryID, amountMinor: -amount, memo: row.memo))
        }
        return result
    }

    private var splitsAreValid: Bool {
        guard isSplit else { return true }
        guard let parsedAmount, let parsedSplits else { return false }
        return parsedSplits.count >= 2 && parsedSplits.reduce(Int64(0)) { $0 + $1.amountMinor } == parsedAmount
    }

    private var remainingSplitAmount: Int64? {
        guard let parsedAmount, let parsedSplits else { return nil }
        return parsedAmount - parsedSplits.reduce(Int64(0)) { $0 + $1.amountMinor }
    }

    private func save() async {
        guard let parsedAmount, let parsedSplits, splitsAreValid else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            try await workspace.createTransaction(
                APITransactionCreate(
                    accountID: accountID,
                    categoryID: isSplit ? nil : categoryID,
                    amountMinor: parsedAmount,
                    occurredOn: formatter.string(from: date),
                    payeeName: payee,
                    memo: memo,
                    isCleared: isCleared,
                    splits: parsedSplits,
                    flag: flag.isEmpty ? nil : flag,
                    tags: commaValues(tags),
                    attachmentMetadata: commaValues(attachments).map { ["name": $0] }
                )
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commaValues(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct SplitDraft: Identifiable {
    let id = UUID()
    var categoryID = ""
    var amount = ""
    var memo = ""
}

struct AllocationTransferView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let categories: [APICategoryMonth]
    let expectedAllocationVersion: Int
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceCategoryID = ""
    @State private var destinationCategoryID = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $sourceCategoryID) {
                    ForEach(categories.filter { $0.availableMinor > 0 }) { category in
                        Text("\(category.name) · \(CurrencyText.editable(category.availableMinor, currencyCode: budget.currencyCode))")
                            .tag(category.categoryID)
                    }
                }
                Picker("To", selection: $destinationCategoryID) {
                    ForEach(categories.filter { $0.categoryID != sourceCategoryID }) { category in
                        Text(category.name).tag(category.categoryID)
                    }
                }
                CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode)
                TextField("Reason (optional)", text: $note)
            }
            .navigationTitle("Move Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { Task { await save() } }.disabled(!isValid || isSaving)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to move money", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .onAppear { selectDefaults() }
            .onChange(of: sourceCategoryID) { _, _ in selectDestination() }
        }
    }

    private var parsedAmount: Int64? {
        guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode), value > 0 else {
            return nil
        }
        return value
    }

    private var isValid: Bool {
        guard let parsedAmount,
              sourceCategoryID != destinationCategoryID,
              let source = categories.first(where: { $0.categoryID == sourceCategoryID }) else { return false }
        return parsedAmount <= source.availableMinor
    }

    private func selectDefaults() {
        if sourceCategoryID.isEmpty {
            sourceCategoryID = categories.first(where: { $0.availableMinor > 0 })?.categoryID ?? ""
        }
        selectDestination()
    }

    private func selectDestination() {
        if destinationCategoryID.isEmpty || destinationCategoryID == sourceCategoryID {
            destinationCategoryID = categories.first(where: { $0.categoryID != sourceCategoryID })?.categoryID ?? ""
        }
    }

    private func save() async {
        guard let parsedAmount else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            try await workspace.moveAllocation(
                APIAllocationTransferCreate(
                    sourceCategoryID: sourceCategoryID,
                    destinationCategoryID: destinationCategoryID,
                    amountMinor: parsedAmount,
                    occurredOn: formatter.string(from: Date()),
                    note: note,
                    expectedAllocationVersion: expectedAllocationVersion
                )
            )
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AssignmentEditView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let category: APICategoryMonth
    let month: String
    let expectedAllocationVersion: Int
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        budget: APIBudget,
        category: APICategoryMonth,
        month: String,
        expectedAllocationVersion: Int,
        serverURL: URL,
        token: String,
        onSaved: @escaping () async -> Void
    ) {
        self.budget = budget
        self.category = category
        self.month = month
        self.expectedAllocationVersion = expectedAllocationVersion
        self.serverURL = serverURL
        self.token = token
        self.onSaved = onSaved
        _amount = State(initialValue: CurrencyText.editable(category.assignedMinor, currencyCode: budget.currencyCode))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(category.name) {
                    CurrencyAmountField("Assigned amount", text: $amount, currencyCode: budget.currencyCode, allowsNegative: true, allowsZero: true)
                    Text("Enter a negative amount to move money back to Ready to Assign.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Assignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || parsedAmount == nil)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var parsedAmount: Int64? {
        CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode)
    }

    private func save() async {
        guard let parsedAmount else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await workspace.updateAssignment(
                categoryID: category.categoryID,
                month: month,
                assignedMinor: parsedAmount,
                expectedVersion: expectedAllocationVersion
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FundingRequestView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let categories: [APICategory]
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var categoryID = ""
    @State private var amount = ""
    @State private var reason = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $categoryID) {
                    ForEach(categories.filter { $0.systemType == nil }) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode)
                TextField("What is this for?", text: $reason, axis: .vertical)
            }
            .navigationTitle("Request Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await save() } }
                        .disabled(parsedAmount == nil || categoryID.isEmpty || isSaving)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to send request", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .onAppear {
                if categoryID.isEmpty {
                    categoryID = categories.first(where: { $0.systemType == nil })?.id ?? ""
                }
            }
        }
    }

    private var parsedAmount: Int64? {
        guard let value = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode),
              value > 0 else { return nil }
        return value
    }

    private func save() async {
        guard let parsedAmount else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await workspace.createRequest(
                APIFinancialRequestCreate(
                    destinationCategoryID: categoryID,
                    requestedAmountMinor: parsedAmount,
                    reason: reason
                )
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum CurrencyText {
    static func parseMinorUnits(_ text: String, currencyCode: String) -> Int64? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.generatesDecimalNumbers = true
        guard let number = formatter.number(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = currencyCode
        let multiplier = NSDecimalNumber(mantissa: 1, exponent: Int16(currencyFormatter.maximumFractionDigits), isNegative: false)
        let scaled = NSDecimalNumber(decimal: number.decimalValue).multiplying(by: multiplier)
        let rounded = scaled.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        guard scaled == rounded,
              rounded.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              rounded.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else {
            return nil
        }
        return rounded.int64Value
    }

    static func editable(_ minorUnits: Int64, currencyCode: String) -> String {
        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = currencyCode
        let digits = currencyFormatter.maximumFractionDigits
        let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(digits), isNegative: false)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(value: minorUnits).dividing(by: divisor)) ?? ""
    }
}

struct CurrencyAmountField: View {
    private let title: String
    @Binding private var text: String
    private let currencyCode: String
    private let allowsNegative: Bool
    private let allowsZero: Bool
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, currencyCode: String, allowsNegative: Bool = false, allowsZero: Bool = false) {
        self.title = title
        _text = text
        self.currencyCode = currencyCode
        self.allowsNegative = allowsNegative
        self.allowsZero = allowsZero
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                TextField("0.00", text: $text)
                    .focused($isFocused)
                    .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 120)
                    .accessibilityLabel(title)
                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(title)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            if !text.isEmpty && !isValid {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
    }

    private var isValid: Bool {
        guard let parsed = CurrencyText.parseMinorUnits(text, currencyCode: currencyCode) else { return false }
        if !allowsNegative && parsed < 0 { return false }
        return allowsZero || parsed != 0
    }

    private var validationMessage: String {
        allowsNegative ? "Enter a valid currency amount." : "Enter a valid non-negative currency amount."
    }
}

struct AccountCreationView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountType = "checking"
    @State private var isOnBudget = true
    @State private var startingBalance = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Account name", text: $name)
                Picker("Type", selection: $accountType) {
                    ForEach(["checking", "savings", "cash", "credit", "loan", "tracking"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                Toggle("Include in budget", isOn: $isOnBudget)
                Section("Current balance") {
                    CurrencyAmountField(
                        "Balance",
                        text: $startingBalance,
                        currencyCode: budget.currencyCode,
                        allowsNegative: true,
                        allowsZero: true
                    )
                    Text(accountType == "credit"
                         ? "Enter existing credit card debt as a negative amount. This records the real balance without treating borrowed money as income."
                         : "Enter the balance as it is today. On-budget cash becomes available to assign after the account is created.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }.disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedStartingBalance == nil)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to create account", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var parsedStartingBalance: Int64? {
        startingBalance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0
            : CurrencyText.parseMinorUnits(startingBalance, currencyCode: budget.currencyCode)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            guard let balance = parsedStartingBalance else { return }
            try await workspace.createAccount(APIAccountCreate(name: name, accountType: accountType, isOnBudget: isOnBudget, startingBalanceMinor: balance))
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct CategoryCreationView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let groups: [APICategoryGroup]
    let serverURL: URL
    let token: String
    let onSaved: () async -> Void
    var delegatedUserID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupID = ""
    @State private var newGroupName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Category name", text: $name)
                if !groups.isEmpty {
                    Picker("Group", selection: $groupID) {
                        ForEach(groups) { Text($0.name).tag($0.id) }
                    }
                }
                if delegatedUserID == nil {
                    TextField(groups.isEmpty ? "First group name" : "Or create a new group", text: $newGroupName)
                } else {
                    Text("This category will be scoped to your delegated budget and cannot increase your total authority.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }.disabled(isSaving || name.isEmpty || targetGroupMissing)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to create category", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
            .onAppear { if groupID.isEmpty { groupID = groups.first?.id ?? "" } }
        }
    }

    private var targetGroupMissing: Bool { groupID.isEmpty && newGroupName.isEmpty }
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await workspace.createCategory(groupID: groupID, newGroupName: newGroupName, name: name, delegatedUserID: delegatedUserID)
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
