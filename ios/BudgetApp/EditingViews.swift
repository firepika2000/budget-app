import BudgetAPI
import SwiftUI

struct TransactionEntryView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let accounts: [APIAccount]
    let categories: [APICategory]
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var categoryID: String?
    @State private var payee = ""
    @State private var payeeID: String?
    @State private var selectedPayeeName = ""
    @State private var showPayeeSelector = false
    @State private var amount = ""
    @State private var memo = ""
    @State private var date = Date()
    @State private var isInflow = false
    @State private var isCleared = false
    @State private var isSplit = false
    @State private var flag = ""
    @State private var tags = ""
    @State private var splitRows = [SplitDraft(), SplitDraft()]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(budget: APIBudget, accounts: [APIAccount], categories: [APICategory], initialAccountID: String? = nil, onSaved: @escaping () async -> Void) {
        self.budget = budget
        self.accounts = accounts
        self.categories = categories
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
                    .onChange(of: payee) { _, value in
                        if payeeID != nil && selectedPayeeName != value { payeeID = nil; selectedPayeeName = "" }
                    }
                Button("Choose saved payee", systemImage: "person.text.rectangle") { showPayeeSelector = true }.accessibilityIdentifier("saved-payee-menu")
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
                Section {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("transaction-date")
                } footer: {
                    Text("Transactions record money that has already happened. Use Schedule Transaction for a future expense, income, or transfer.")
                }
                TextField("Memo", text: $memo)
                Picker("Flag", selection: $flag) { Text("None").tag(""); Text("Red").tag("red"); Text("Orange").tag("orange"); Text("Yellow").tag("yellow"); Text("Green").tag("green"); Text("Blue").tag("blue"); Text("Purple").tag("purple") }
                TextField("Tags (comma separated)", text: $tags)
                Text("Save the transaction, then add PDF or image attachments from its detail screen.").font(.footnote).foregroundStyle(.secondary)
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
            .sheet(isPresented: $showPayeeSelector) {
                PayeeSearchSelectionView { item in
                    payeeID = item.id; payee = item.displayName; selectedPayeeName = item.displayName
                    if categoryID == nil, let suggested = item.defaultCategoryID { categoryID = suggested }
                }
            }
        }
    }

    private var parsedAmount: Int64? {
        guard let magnitude = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode),
              magnitude >= 0 else { return nil }
        return isInflow ? magnitude : -magnitude
    }

    private var parsedSplits: [TransactionSplitOperation]? {
        guard isSplit else { return [] }
        var result: [TransactionSplitOperation] = []
        for row in splitRows {
            guard !row.categoryID.isEmpty,
                  let amount = CurrencyText.parseMinorUnits(row.amount, currencyCode: budget.currencyCode),
                  amount >= 0 else { return nil }
            result.append(TransactionSplitOperation(categoryID: row.categoryID, amountMinor: -amount, memo: row.memo))
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
                RecordTransactionOperation(
                    accountID: accountID,
                    categoryID: isSplit ? nil : categoryID,
                    amountMinor: parsedAmount,
                    occurredOn: formatter.string(from: date),
                    payeeName: payee,
                    payeeID: payeeID,
                    memo: memo,
                    isCleared: isCleared,
                    splits: parsedSplits,
                    flag: flag.isEmpty ? nil : flag,
                    tags: commaValues(tags),
                    attachmentMetadata: []
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
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceCategoryID: String
    @State private var destinationCategoryID = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(budget: APIBudget, categories: [APICategoryMonth], expectedAllocationVersion: Int, initialSourceCategoryID: String? = nil, onSaved: @escaping () async -> Void) {
        self.budget = budget
        self.categories = categories
        self.expectedAllocationVersion = expectedAllocationVersion
        self.onSaved = onSaved
        _sourceCategoryID = State(initialValue: initialSourceCategoryID ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $sourceCategoryID) {
                    ForEach(categories.filter { $0.availableMinor > 0 }) { category in
                        Text("\(category.name) · \(workspace.format(category.availableMinor))")
                            .tag(category.categoryID)
                    }
                }
                .accessibilityIdentifier("move-source-category")
                .accessibilityValue(categories.first(where: { $0.categoryID == sourceCategoryID })?.name ?? "Select category")
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
                MoveMoneyOperation(
                    sourceCategoryID: sourceCategoryID,
                    destinationCategoryID: destinationCategoryID,
                    amountMinor: parsedAmount,
                    occurredOn: formatter.string(from: Date()),
                    note: note,
                    expectedVersion: expectedAllocationVersion
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
        onSaved: @escaping () async -> Void
    ) {
        self.budget = budget
        self.category = category
        self.month = month
        self.expectedAllocationVersion = expectedAllocationVersion
        self.onSaved = onSaved
        _amount = State(initialValue: CurrencyText.editable(category.assignedMinor, currencyCode: budget.currencyCode))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(category.name) {
                    CurrencyAmountField("Assigned amount", text: $amount, currencyCode: budget.currencyCode, allowsNegative: true, allowsZero: true)
                    Text("Enter a negative amount to move money back to Unassigned.")
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
    let onSaved: () async -> Void
    let request: APIFinancialRequest?

    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: String
    @State private var amount: String
    @State private var reason: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(budget: APIBudget, categories: [APICategory], request: APIFinancialRequest? = nil, onSaved: @escaping () async -> Void) {
        self.budget = budget; self.categories = categories; self.request = request; self.onSaved = onSaved
        _categoryID = State(initialValue: request?.destinationCategoryID ?? "")
        _amount = State(initialValue: request.map { CurrencyText.editable($0.requestedAmountMinor, currencyCode: budget.currencyCode) } ?? "")
        _reason = State(initialValue: request?.reason ?? "")
    }

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
            .navigationTitle(request == nil ? "Request Money" : "Revise Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request == nil ? "Send" : "Resubmit") { Task { await save() } }
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
            let value = APIFinancialRequestCreate(
                    destinationCategoryID: categoryID,
                    requestedAmountMinor: parsedAmount,
                    reason: reason
                )
            if let request { try await workspace.reviseRequest(id: request.id, version: request.version, value: value) }
            else { try await workspace.createRequest(value) }
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
    private let onFocusChange: ((Bool) -> Void)?
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, currencyCode: String, allowsNegative: Bool = false, allowsZero: Bool = false, onFocusChange: ((Bool) -> Void)? = nil) {
        self.title = title
        _text = text
        self.currencyCode = currencyCode
        self.allowsNegative = allowsNegative
        self.allowsZero = allowsZero
        self.onFocusChange = onFocusChange
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
                // Keep this control in the hierarchy while the buffer is empty. Removing it when
                // the last character is deleted causes current SwiftUI Form rows to rebuild the
                // adjacent TextField and lose its active input target.
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(text.isEmpty ? 0 : 1)
                .allowsHitTesting(!text.isEmpty)
                .accessibilityHidden(text.isEmpty)
                .accessibilityLabel("Clear \(title)")
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
        .onChange(of: isFocused) { _, focused in onFocusChange?(focused) }
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
                TextField("Account name", text: $name).accessibilityIdentifier("new-account-name")
                Picker("Budget treatment", selection: $isOnBudget) {
                    Text("On budget").tag(true)
                    Text("Tracking").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("new-account-treatment")
                .onChange(of: isOnBudget) { _, value in accountType = value ? "checking" : "tracking" }
                Picker("Type", selection: $accountType) {
                    ForEach(availableTypes, id: \.self) {
                        Text(accountTypeTitle($0)).tag($0)
                    }
                }
                .accessibilityIdentifier("new-account-type")
                Text(isOnBudget
                     ? "Budget accounts participate in Unassigned and category planning."
                     : "Tracking accounts affect net worth only and never create money to assign.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    private var availableTypes: [String] { isOnBudget ? ["checking", "savings", "cash", "credit"] : ["tracking", "loan"] }

    private func accountTypeTitle(_ type: String) -> String {
        switch type { case "credit": "Credit Card"; case "loan": "Loan / Liability"; case "tracking": "Asset / Tracking"; default: type.capitalized }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            guard let balance = parsedStartingBalance else { return }
            try await workspace.createAccount(CreateAccountOperation(name: name, kind: accountType, isOnBudget: isOnBudget, openingBalanceMinor: balance))
            await onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let account: APIAccount
    @State private var name: String
    @State private var accountType: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDebtTerms = false

    init(account: APIAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _accountType = State(initialValue: account.accountType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Account name", text: $name).accessibilityIdentifier("account-settings-name")
                    Picker("Type", selection: $accountType) {
                        ForEach(safeTypes, id: \.self) { Text(typeTitle($0)).tag($0) }
                    }
                    .accessibilityIdentifier("account-settings-type")
                    LabeledContent("Budget treatment", value: account.isOnBudget ? "On budget" : "Tracking")
                }
                Section {
                    Text("Budget treatment cannot be changed after creation because doing so would reinterpret Unassigned, category activity, transfers, and historical reports.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Balances are not account metadata. Correct them with transactions or Reconcile from the account register.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if ["credit", "loan"].contains(account.accountType) {
                    Section("Debt planning") {
                        Button {
                            showDebtTerms = true
                        } label: {
                            Label("Debt Terms", systemImage: "percent")
                        }
                        .accessibilityIdentifier("account-debt-terms-action")
                        Text("Optional planning inputs. Editing them does not change this account's balance, reconciliation, categories, or Ready to Assign.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Account Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to update account", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showDebtTerms) {
                DebtTermsEditorView(account: account)
                    .environmentObject(workspace)
            }
        }
    }

    private var safeTypes: [String] {
        if account.isOnBudget { return ["checking", "savings", "cash"].contains(account.accountType) ? ["checking", "savings", "cash"] : [account.accountType] }
        return ["loan", "tracking"].contains(account.accountType) ? ["tracking", "loan"] : [account.accountType]
    }

    private func typeTitle(_ type: String) -> String {
        switch type { case "credit": "Credit Card"; case "loan": "Loan / Liability"; case "tracking": "Asset / Tracking"; default: type.capitalized }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await workspace.updateAccount(.init(accountID: account.id, name: name, currentKind: account.accountType, kind: accountType, isOnBudget: account.isOnBudget))
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct DebtTermsEditorView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let account: APIAccount
    @State private var apr = ""
    @State private var rateType = "fixed"
    @State private var frequency = "monthly"
    @State private var payment = ""
    @State private var minimumRule = "fixed"
    @State private var minimumRate = ""
    @State private var dueDay = ""
    @State private var statementDay = ""
    @State private var originalPrincipal = ""
    @State private var originalTerm = ""
    @State private var remainingTerm = ""
    @State private var promoRate = ""
    @State private var promoEnd = ""
    @State private var hasStoredTerms = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isCard: Bool { account.accountType == "credit" }
    private var currencyCode: String { workspace.budget.currencyCode }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rate") {
                    TextField("APR (%)", text: $apr)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("debt-apr")
                    Picker("Rate", selection: $rateType) {
                        Text("Fixed").tag("fixed")
                        Text("Variable").tag("variable")
                    }
                }
                if isCard { creditCardFields } else { installmentFields }
                Section("Projection readiness") {
                    Text(readinessMessage)
                        .foregroundStyle(isReady ? Color.secondary : Color.orange)
                    Text("These are planning assumptions. Posted balances and actual interest remain separate financial facts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if hasStoredTerms {
                    Section {
                        Button("Remove Debt Terms", role: .destructive) { Task { await remove() } }
                    }
                }
            }
            .navigationTitle("Debt Terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isLoading || isSaving || !inputsValid)
                        .accessibilityIdentifier("save-debt-terms")
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
            .alert("Unable to update debt terms", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    @ViewBuilder private var creditCardFields: some View {
        Section("Minimum payment") {
            Picker("Rule", selection: $minimumRule) {
                Text("Fixed amount").tag("fixed")
                Text("Percentage").tag("percentage")
                Text("Greater of both").tag("greater_of")
            }
            if minimumRule != "percentage" {
                CurrencyAmountField("Fixed amount", text: $payment, currencyCode: currencyCode, allowsNegative: false, allowsZero: true)
                    .accessibilityIdentifier("debt-payment")
            }
            if minimumRule != "fixed" {
                TextField("Balance percentage (%)", text: $minimumRate).keyboardType(.decimalPad)
            }
        }
        Section("Cycle") {
            TextField("Payment due day", text: $dueDay).keyboardType(.numberPad).accessibilityIdentifier("debt-due-day")
            TextField("Statement closing day", text: $statementDay).keyboardType(.numberPad)
        }
        Section("Promotional rate (optional)") {
            TextField("Promotional APR (%)", text: $promoRate).keyboardType(.decimalPad)
            TextField("End date (YYYY-MM-DD)", text: $promoEnd).textInputAutocapitalization(.never)
        }
    }

    @ViewBuilder private var installmentFields: some View {
        Section("Scheduled payment") {
            Picker("Frequency", selection: $frequency) {
                Text("Weekly").tag("weekly")
                Text("Every two weeks").tag("biweekly")
                Text("Monthly").tag("monthly")
            }
            CurrencyAmountField("Payment", text: $payment, currencyCode: currencyCode, allowsNegative: false, allowsZero: true)
                .accessibilityIdentifier("debt-payment")
            TextField("Payment due day", text: $dueDay).keyboardType(.numberPad).accessibilityIdentifier("debt-due-day")
        }
        Section("Original agreement (optional)") {
            CurrencyAmountField("Original principal", text: $originalPrincipal, currencyCode: currencyCode, allowsNegative: false, allowsZero: true)
            TextField("Original term (months)", text: $originalTerm).keyboardType(.numberPad)
            TextField("Remaining term (months)", text: $remainingTerm).keyboardType(.numberPad)
        }
    }

    private var aprBasisPoints: Int? { Self.parseBasisPoints(apr) }
    private var minimumBasisPoints: Int? { Self.parseBasisPoints(minimumRate) }
    private var promoBasisPoints: Int? { Self.parseBasisPoints(promoRate) }
    private var paymentMinor: Int64? { optionalMoney(payment) }
    private var principalMinor: Int64? { optionalMoney(originalPrincipal) }
    private var inputsValid: Bool {
        validOptional(apr, aprBasisPoints) && validOptional(dueDay, Int(dueDay))
            && (!isCard || (validOptional(statementDay, Int(statementDay))
                && validOptional(minimumRate, minimumBasisPoints)
                && validOptional(promoRate, promoBasisPoints)
                && (promoEnd.isEmpty || Self.validISODate(promoEnd))))
            && (isCard || (validOptional(payment, paymentMinor)
                && validOptional(originalPrincipal, principalMinor)
                && validOptional(originalTerm, Int(originalTerm))
                && validOptional(remainingTerm, Int(remainingTerm))))
            && (isCard && minimumRule != "percentage" ? validOptional(payment, paymentMinor) : true)
    }
    private var isReady: Bool {
        let cardPaymentReady = minimumRule == "fixed" ? paymentMinor != nil
            : minimumRule == "percentage" ? minimumBasisPoints != nil
            : minimumRule == "greater_of" ? (paymentMinor != nil && minimumBasisPoints != nil)
            : false
        return aprBasisPoints != nil && Int(dueDay) != nil
            && (isCard ? cardPaymentReady : paymentMinor != nil)
    }
    private var readinessMessage: String {
        isReady ? "Ready for projected payoff calculations." : "Projection unavailable until APR, due day, and the required payment rule are complete."
    }

    private func validOptional<T>(_ text: String, _ value: T?) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value != nil }
    private func optionalMoney(_ text: String) -> Int64? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : CurrencyText.parseMinorUnits(text, currencyCode: currencyCode)
    }
    private static func parseBasisPoints(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0 else { return nil }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let result = NSDecimalNumber(decimal: rounded).intValue
        return result <= 100_000 ? result : nil
    }
    private static func validISODate(_ value: String) -> Bool {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) != nil
    }
    private static func percentText(_ basisPoints: Int?) -> String {
        guard let basisPoints else { return "" }
        return NSDecimalNumber(value: basisPoints).dividing(by: 100).stringValue
    }

    private func load() async {
        defer { isLoading = false }
        do {
            guard let value = try await workspace.accountDebtTerms(accountID: account.id) else { return }
            hasStoredTerms = true; apr = Self.percentText(value.annualRateBasisPoints)
            rateType = value.rateType ?? "fixed"; frequency = value.paymentFrequency ?? "monthly"
            payment = value.scheduledPaymentMinor.map { CurrencyText.editable($0, currencyCode: currencyCode) }
                ?? value.minimumPaymentMinor.map { CurrencyText.editable($0, currencyCode: currencyCode) } ?? ""
            minimumRule = value.minimumPaymentRule ?? "fixed"
            minimumRate = Self.percentText(value.minimumPaymentRateBasisPoints)
            dueDay = value.dueDay.map(String.init) ?? ""; statementDay = value.statementDay.map(String.init) ?? ""
            originalPrincipal = value.originalPrincipalMinor.map { CurrencyText.editable($0, currencyCode: currencyCode) } ?? ""
            originalTerm = value.originalTermMonths.map(String.init) ?? ""; remainingTerm = value.remainingTermMonths.map(String.init) ?? ""
            promoRate = Self.percentText(value.promotionalRateBasisPoints); promoEnd = value.promotionalEndsOn ?? ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() async {
        isSaving = true; defer { isSaving = false }
        let value = APIAccountDebtTermsUpsert(
            termsType: isCard ? "credit_card" : "installment_loan", annualRateBasisPoints: aprBasisPoints,
            rateType: rateType, paymentFrequency: isCard ? "monthly" : frequency,
            scheduledPaymentMinor: isCard ? nil : paymentMinor, minimumPaymentRule: isCard ? minimumRule : nil,
            minimumPaymentMinor: isCard && minimumRule != "percentage" ? paymentMinor : nil,
            minimumPaymentRateBasisPoints: isCard && minimumRule != "fixed" ? minimumBasisPoints : nil,
            dueDay: Int(dueDay), statementDay: isCard ? Int(statementDay) : nil,
            originalPrincipalMinor: isCard ? nil : principalMinor, originalTermMonths: isCard ? nil : Int(originalTerm),
            remainingTermMonths: isCard ? nil : Int(remainingTerm), promotionalRateBasisPoints: isCard ? promoBasisPoints : nil,
            promotionalEndsOn: isCard && !promoEnd.isEmpty ? promoEnd : nil
        )
        do { _ = try await workspace.updateAccountDebtTerms(accountID: account.id, value: value); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }

    private func remove() async {
        isSaving = true; defer { isSaving = false }
        do { try await workspace.deleteAccountDebtTerms(accountID: account.id); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct CategoryCreationView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let groups: [APICategoryGroup]
    let onSaved: () async -> Void
    var initialGroupID: String = ""
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
                TextField("Category name", text: $name).accessibilityIdentifier("new-category-name")
                if categoryNameConflict {
                    Text("A category with this name already exists in the selected group.")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("category-name-conflict")
                }
                if !groups.isEmpty {
                    Picker("Group", selection: $groupID) {
                        ForEach(groups) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("new-category-group")
                    .accessibilityValue(groups.first(where: { $0.id == groupID })?.name ?? "No group selected")
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
                    Button("Create") { Task { await save() } }.disabled(isSaving || normalizedCategoryName(name).isEmpty || targetGroupMissing || categoryNameConflict)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .alert("Unable to create category", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
            .onAppear { if groupID.isEmpty { groupID = groups.contains(where: { $0.id == initialGroupID }) ? initialGroupID : groups.first?.id ?? "" } }
        }
    }

    private var targetGroupMissing: Bool { groupID.isEmpty && newGroupName.isEmpty }
    private var categoryNameConflict: Bool {
        guard newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !groupID.isEmpty else { return false }
        let key = normalizedCategoryName(name)
        return !key.isEmpty && workspace.categories.contains { $0.groupID == groupID && normalizedCategoryName($0.name) == key }
    }
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
