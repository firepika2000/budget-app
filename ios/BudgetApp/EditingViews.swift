import BudgetAPI
import SwiftUI

struct TransactionEntryView: View {
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
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Account", selection: $accountID) {
                    ForEach(accounts.filter { !$0.isClosed }) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                TextField("Payee", text: $payee)
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                Toggle("Income / inflow", isOn: $isInflow)
                Picker("Category", selection: $categoryID) {
                    Text(isInflow ? "Ready to assign" : "Uncategorized")
                        .tag(nil as String?)
                    ForEach(categories.filter { !$0.isArchived }) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Memo", text: $memo)
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
                        .disabled(isSaving || accountID.isEmpty || parsedAmount == nil)
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
                if inflow { categoryID = nil }
            }
        }
    }

    private var parsedAmount: Int64? {
        guard let magnitude = CurrencyText.parseMinorUnits(amount, currencyCode: budget.currencyCode),
              magnitude >= 0 else { return nil }
        return isInflow ? magnitude : -magnitude
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
            let client = try APIClient(baseURL: serverURL)
            _ = try await client.createTransaction(
                budgetID: budget.id,
                transaction: APITransactionCreate(
                    accountID: accountID,
                    categoryID: categoryID,
                    amountMinor: parsedAmount,
                    occurredOn: formatter.string(from: date),
                    payeeName: payee,
                    memo: memo,
                    isCleared: isCleared
                ),
                token: token
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AssignmentEditView: View {
    let budget: APIBudget
    let category: APICategoryMonth
    let month: String
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
        serverURL: URL,
        token: String,
        onSaved: @escaping () async -> Void
    ) {
        self.budget = budget
        self.category = category
        self.month = month
        self.serverURL = serverURL
        self.token = token
        self.onSaved = onSaved
        _amount = State(initialValue: CurrencyText.editable(category.assignedMinor, currencyCode: budget.currencyCode))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(category.name) {
                    TextField("Assigned amount", text: $amount)
                        .keyboardType(.numbersAndPunctuation)
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
            _ = try await APIClient(baseURL: serverURL).updateAssignment(
                budgetID: budget.id,
                categoryID: category.categoryID,
                month: month,
                assignedMinor: parsedAmount,
                token: token
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
        let divisor = pow(10.0, Double(digits))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: Double(minorUnits) / divisor)) ?? ""
    }
}
