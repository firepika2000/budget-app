import BudgetAPI
import AVFoundation
import PhotosUI
import SwiftUI

struct TransactionEntryView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    let budget: APIBudget
    let accounts: [APIAccount]
    let categories: [APICategory]
    let groups: [APICategoryGroup]
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var categoryID: String?
    @State private var payee = ""
    @State private var payeeID: String?
    @State private var selectedPayeeName = ""
    @State private var suggestedCategoryID: String?
    @State private var showPayeeSelector = false
    @State private var amount = ""
    @State private var memo = ""
    @State private var financialClassification = ""
    @State private var date = Date()
    @State private var isInflow = false
    @State private var isCleared = false
    @State private var isSplit = false
    @State private var flag = ""
    @State private var tags = ""
    @State private var splitRows = [SplitDraft(), SplitDraft()]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var choosingReceiptPhoto = false
    @State private var showingReceiptCamera = false
    @State private var capturedReceiptData: Data?
    @State private var receiptSuggestion: ReceiptSuggestion?
    @State private var isScanningReceipt = false

    init(budget: APIBudget, accounts: [APIAccount], categories: [APICategory], groups: [APICategoryGroup] = [], initialAccountID: String? = nil, initialCategoryID: String? = nil, initialPayee: String? = nil, initialAmount: String? = nil, initialMemo: String? = nil, initialDate: Date? = nil, initialIsInflow: Bool = false, onSaved: @escaping () async -> Void) {
        self.budget = budget
        self.accounts = accounts
        self.categories = categories
        self.groups = groups
        self.onSaved = onSaved
        _accountID = State(initialValue: initialAccountID ?? "")
        _categoryID = State(initialValue: initialCategoryID)
        _payee = State(initialValue: initialPayee ?? "")
        _amount = State(initialValue: initialAmount ?? "")
        _memo = State(initialValue: initialMemo ?? "")
        _date = State(initialValue: initialDate ?? Date())
        _isInflow = State(initialValue: initialIsInflow)
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
                    .accessibilityIdentifier("transaction-payee")
                    .onChange(of: payee) { _, value in
                        if payeeID != nil && selectedPayeeName != value { payeeID = nil; selectedPayeeName = ""; suggestedCategoryID = nil }
                    }
                Button("Choose saved payee", systemImage: "person.text.rectangle") { showPayeeSelector = true }.accessibilityIdentifier("saved-payee-menu")
                CurrencyAmountField("Amount", text: $amount, currencyCode: budget.currencyCode)
                    .accessibilityIdentifier("transaction-amount")
                Toggle("Income / inflow", isOn: $isInflow)
                    .accessibilityIdentifier("transaction-inflow")
                if selectedAccountIsDebt && !isInflow && !isSplit {
                    Picker("Classification", selection: $financialClassification) {
                        Text("Ordinary transaction").tag("")
                        Text("Interest charge").tag("interest_charge")
                    }
                    .accessibilityIdentifier("transaction-classification")
                }
                Toggle("Split across categories", isOn: $isSplit)
                    .disabled(isInflow)
                if isSplit {
                    Section("Splits") {
                        ForEach($splitRows) { $row in
                            Picker("Category", selection: $row.categoryID) {
                                Text("Select category").tag("")
                                ForEach(categories.filter { !$0.isArchived }) { category in
                                    Text(categoryLabel(category)).tag(category.id)
                                }
                            }
                            CurrencyAmountField("Split amount", text: $row.amount, currencyCode: budget.currencyCode, allowsZero: true)
                            TextField("Split memo", text: $row.memo)
                            if selectedAccountIsDebt {
                                Picker("Split classification", selection: $row.financialClassification) {
                                    Text("Ordinary").tag("")
                                    Text("Interest charge").tag("interest_charge")
                                }
                            }
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
                            Text(categoryLabel(category)).tag(Optional(category.id))
                        }
                    }
                    if categoryID == nil, let suggestion = suggestedCategoryID,
                       let category = categories.first(where: { $0.id == suggestion && !$0.isArchived }) {
                        HStack {
                            Label("Suggested: \(categoryLabel(category))", systemImage: "sparkles")
                                .font(.subheadline)
                            Spacer()
                            Button("Use") { categoryID = suggestion; suggestedCategoryID = nil }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("use-category-suggestion")
                        }
                        .accessibilityIdentifier("category-suggestion")
                    }
                    if isInflow, categoryID != nil {
                        Text("Categorized inflows reduce this category's spending, such as a refund or reimbursement. Leave the category empty for new income ready to assign.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("categorized-inflow-explanation")
                    }
                }
                Section {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("transaction-date")
                } footer: {
                    Text("Transactions record money that has already happened. Use Schedule Transaction for a future expense, income, or transfer.")
                }
                TextField("Memo", text: $memo)
                    .accessibilityIdentifier("transaction-memo")
                Picker("Flag", selection: $flag) { Text("None").tag(""); Text("Red").tag("red"); Text("Orange").tag("orange"); Text("Yellow").tag("yellow"); Text("Green").tag("green"); Text("Blue").tag("blue"); Text("Purple").tag("purple") }
                TextField("Tags (comma separated)", text: $tags)
                Section("Receipt assistance") {
                    Button { requestReceiptCamera() } label: {
                        Label("Take Receipt Photo", systemImage: "camera")
                    }
                    .disabled(isScanningReceipt)
                    .accessibilityIdentifier("take-receipt-photo")
                    Button { choosingReceiptPhoto = true } label: {
                        Label("Scan Receipt Photo", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(isScanningReceipt)
                    .accessibilityIdentifier("scan-receipt-photo")
                    if isScanningReceipt { ProgressView("Reading on this iPhone…") }
                    Text("ClearPocket reads the image on this device and proposes fields for your review. Nothing is saved automatically. Camera captures are used only for suggestions and are not saved to Photos or attached; add an attachment from transaction detail after saving if you want to retain a receipt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                    isSplit = false
                    financialClassification = ""
                }
            }
            .onChange(of: accountID) { _, _ in if !selectedAccountIsDebt { financialClassification = "" } }
            .photosPicker(isPresented: $choosingReceiptPhoto, selection: $receiptPhoto, matching: .images)
            .onChange(of: receiptPhoto) { _, item in
                if let item, !choosingReceiptPhoto { Task { await scanReceipt(item) } }
            }
            .onChange(of: choosingReceiptPhoto) { _, presented in
                if !presented, let item = receiptPhoto { Task { await scanReceipt(item) } }
            }
            .sheet(isPresented: $showingReceiptCamera, onDismiss: {
                if let data = capturedReceiptData {
                    capturedReceiptData = nil
                    Task { await scanReceiptData(data) }
                }
            }) {
                AttachmentCameraPicker { image in
                    capturedReceiptData = image.jpegData(compressionQuality: 0.9)
                    if capturedReceiptData == nil { errorMessage = "The camera image could not be read. Please try again." }
                }
            }
            .sheet(item: $receiptSuggestion) { suggestion in
                ReceiptSuggestionReview(suggestion: suggestion, currencyCode: budget.currencyCode, categoryName: categories.first(where: { $0.id == suggestion.categoryID }).map { workspace.categoryDisplayName($0) }) {
                    Task { await apply(suggestion) }
                }
            }
            .sheet(isPresented: $showPayeeSelector) {
                PayeeSearchSelectionView { item in
                    payeeID = item.id; payee = item.displayName; selectedPayeeName = item.displayName
                    if categoryID == nil, let preferred = item.defaultCategoryID,
                       categories.contains(where: { $0.id == preferred && !$0.isArchived }) {
                        categoryID = preferred; suggestedCategoryID = nil
                    } else if categoryID == nil {
                        suggestedCategoryID = workspace.suggestedCategoryID(forPayeeID: item.id)
                    }
                }
            }
        }
    }

    private func categoryLabel(_ category: APICategory) -> String {
        guard let group = groups.first(where: { $0.id == category.groupID }) else { return category.name }
        return "\(group.name) · \(category.name)"
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
            result.append(TransactionSplitOperation(categoryID: row.categoryID, amountMinor: -amount, memo: row.memo, financialClassification: row.financialClassification.isEmpty ? nil : row.financialClassification))
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
                    financialClassification: financialClassification.isEmpty || isSplit ? nil : financialClassification,
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

    private var selectedAccountIsDebt: Bool {
        guard let type = accounts.first(where: { $0.id == accountID })?.accountType else { return false }
        return ["credit", "loan", "mortgage"].contains(type)
    }

    private func commaValues(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func scanReceipt(_ item: PhotosPickerItem) async {
        guard !isScanningReceipt, receiptSuggestion == nil else { return }
        isScanningReceipt = true; defer { isScanningReceipt = false; receiptPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptOCRError.invalidImage }
            receiptSuggestion = try await ReceiptOCR.recognize(data, currencyCode: budget.currencyCode, categories: categories.filter { !$0.isArchived })
        } catch { errorMessage = error.localizedDescription }
    }

    private func scanReceiptData(_ data: Data) async {
        guard !isScanningReceipt, receiptSuggestion == nil else { return }
        isScanningReceipt = true; defer { isScanningReceipt = false }
        do {
            receiptSuggestion = try await ReceiptOCR.recognize(data, currencyCode: budget.currencyCode,
                categories: categories.filter { !$0.isArchived })
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestReceiptCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "Camera is not available on this device. Choose a receipt photo instead."; return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showingReceiptCamera = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { showingReceiptCamera = true }
                else { errorMessage = "Camera access was denied. Enable it in Settings or choose a receipt photo." }
            }
        case .denied, .restricted:
            errorMessage = "Camera access is unavailable. Enable it in Settings or choose a receipt photo."
        @unknown default: errorMessage = "Camera access is unavailable. Choose a receipt photo."
        }
    }

    private func apply(_ suggestion: ReceiptSuggestion) async {
        if let value = suggestion.amountMinor { amount = CurrencyText.editable(value, currencyCode: budget.currencyCode) }
        if let value = suggestion.occurredOn { date = value }
        if let value = suggestion.categoryID { categoryID = value }
        if let candidate = suggestion.payee, !candidate.isEmpty {
            payee = candidate; payeeID = nil; selectedPayeeName = ""
            if let page = try? await workspace.searchPayees(query: candidate, includeArchived: false, limit: 10),
               let existing = page.items.first(where: { $0.displayName.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                payee = existing.displayName; payeeID = existing.id; selectedPayeeName = existing.displayName
                if categoryID == nil, let preferred = existing.defaultCategoryID { categoryID = preferred }
            }
        }
        receiptSuggestion = nil
    }
}

private struct ReceiptSuggestionReview: View {
    @Environment(\.dismiss) private var dismiss
    let suggestion: ReceiptSuggestion
    let currencyCode: String
    let categoryName: String?
    let onApply: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("Proposed fields") {
                    LabeledContent("Payee", value: suggestion.payee ?? "Not found")
                    LabeledContent("Amount", value: suggestion.amountMinor.map { CurrencyText.editable($0, currencyCode: currencyCode) } ?? "Not found")
                    LabeledContent("Date", value: suggestion.occurredOn?.formatted(date: .abbreviated, time: .omitted) ?? "Not found")
                    LabeledContent("Category", value: categoryName ?? "No suggestion")
                }
                Section("Recognized text") { Text(suggestion.recognizedText).textSelection(.enabled).font(.caption.monospaced()) }
                Section { Text("Review the proposed fields before applying them. Applying fills the draft only; Save remains required to create the transaction.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Review Receipt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply Suggestions") { onApply(); dismiss() }.accessibilityIdentifier("apply-receipt-suggestions") }
            }
        }
    }
}

private struct SplitDraft: Identifiable {
    let id = UUID()
    var categoryID = ""
    var amount = ""
    var memo = ""
    var financialClassification = ""
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
    static func display(_ minorUnits: Int64, currencyCode: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        let digits = formatter.maximumFractionDigits
        let amount = NSDecimalNumber(mantissa: minorUnits.magnitude, exponent: -Int16(digits), isNegative: minorUnits < 0).decimalValue
        return amount.formatted(.currency(code: currencyCode).locale(locale).precision(.fractionLength(digits)))
    }

    static func parseMinorUnits(_ text: String, currencyCode: String) -> Int64? {
        var expression = CurrencyExpression(text: text, locale: .current)
        guard let amount = expression.value else { return nil }
        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = currencyCode
        let multiplier = NSDecimalNumber(mantissa: 1, exponent: Int16(currencyFormatter.maximumFractionDigits), isNegative: false)
        let scaled = NSDecimalNumber(decimal: amount).multiplying(by: multiplier)
        let rounded = scaled.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        guard scaled == rounded,
              rounded.compare(NSDecimalNumber(value: Int64.max)) != ComparisonResult.orderedDescending,
              rounded.compare(NSDecimalNumber(value: Int64.min)) != ComparisonResult.orderedAscending else {
            return nil
        }
        return rounded.int64Value
    }

    private struct CurrencyExpression {
        private var characters: [Character]
        private var index = 0

        init(text: String, locale: Locale) {
            let formatter = NumberFormatter(); formatter.locale = locale
            let decimal = formatter.decimalSeparator ?? "."
            let grouping = formatter.groupingSeparator ?? ","
            let normalized = text
                .replacingOccurrences(of: grouping, with: "")
                .replacingOccurrences(of: decimal, with: ".")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .filter { !$0.isWhitespace }
            characters = Array(normalized)
        }

        var value: Decimal? {
            mutating get {
                guard !characters.isEmpty, let result = expression(), index == characters.count else { return nil }
                return result.isFinite ? result : nil
            }
        }

        private mutating func expression() -> Decimal? {
            guard var value = term() else { return nil }
            while let symbol = peek(), symbol == "+" || symbol == "-" {
                index += 1
                guard let right = term(), let result = calculate(value, right, symbol) else { return nil }
                value = result
            }
            return value
        }

        private mutating func term() -> Decimal? {
            guard var value = factor() else { return nil }
            while let symbol = peek(), symbol == "*" || symbol == "/" {
                index += 1
                guard let right = factor(), symbol != "/" || right != 0,
                      let result = calculate(value, right, symbol) else { return nil }
                value = result
            }
            return value
        }

        private mutating func factor() -> Decimal? {
            if peek() == "+" { index += 1; return factor() }
            if peek() == "-" { index += 1; return factor().flatMap { calculate(0, $0, "-") } }
            if peek() == "(" {
                index += 1
                guard let value = expression(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            return number()
        }

        private mutating func number() -> Decimal? {
            let start = index
            var sawDigit = false, sawDecimal = false
            while let value = peek() {
                if value.isNumber { sawDigit = true; index += 1 }
                else if value == "." && !sawDecimal { sawDecimal = true; index += 1 }
                else { break }
            }
            guard sawDigit else { return nil }
            return Decimal(string: String(characters[start..<index]), locale: Locale(identifier: "en_US_POSIX"))
        }

        private func peek() -> Character? { index < characters.count ? characters[index] : nil }

        private func calculate(_ left: Decimal, _ right: Decimal, _ symbol: Character) -> Decimal? {
            var left = left, right = right, result = Decimal()
            let error: Decimal.CalculationError
            switch symbol {
            case "+": error = NSDecimalAdd(&result, &left, &right, .plain)
            case "-": error = NSDecimalSubtract(&result, &left, &right, .plain)
            case "*": error = NSDecimalMultiply(&result, &left, &right, .plain)
            case "/": error = NSDecimalDivide(&result, &left, &right, .plain)
            default: return nil
            }
            return error == .noError ? result : nil
        }
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
                    .keyboardType(.numbersAndPunctuation)
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
                Button("+") { text += "+" }.accessibilityLabel("Add")
                Button("−") { text += "-" }.accessibilityLabel("Subtract")
                Button("×") { text += "*" }.accessibilityLabel("Multiply")
                Button("÷") { text += "/" }.accessibilityLabel("Divide")
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

    private var availableTypes: [String] { isOnBudget ? ["checking", "savings", "cash", "credit"] : ["asset", "tracking", "loan", "mortgage"] }

    private func accountTypeTitle(_ type: String) -> String {
        switch type { case "credit": "Credit Card"; case "loan": "Loan / Liability"; case "mortgage": "Mortgage"; case "asset": "Asset"; case "tracking": "Other Tracking"; default: type.capitalized }
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
    @State private var showHistory = false
    @State private var isClosed: Bool
    @State private var confirmStatusChange = false

    init(account: APIAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _accountType = State(initialValue: account.accountType)
        _isClosed = State(initialValue: account.isClosed)
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
                if ["credit", "loan", "mortgage"].contains(account.accountType) {
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
                Section("Status") {
                    LabeledContent("Account", value: isClosed ? "Closed" : "Open")
                    Button(isClosed ? "Reopen Account" : "Close Account", systemImage: isClosed ? "arrow.uturn.backward.circle" : "archivebox", role: isClosed ? nil : .destructive) { confirmStatusChange = true }
                        .accessibilityIdentifier(isClosed ? "reopen-account-action" : "close-account-action")
                    Text(isClosed ? "Reopening allows new transactions, transfers, and reconciliation again." : "Closing keeps all history and balances but removes the account from new transaction and transfer choices.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("History") {
                    Button { showHistory = true } label: {
                        Label("Account History", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("account-history-action")
                    Text("See when this account was created, renamed, retyped, closed, or reopened—and who made each change.")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .sheet(isPresented: $showHistory) {
                AccountHistoryView(account: account).environmentObject(workspace)
            }
            .confirmationDialog(isClosed ? "Reopen this account?" : "Close this account?", isPresented: $confirmStatusChange) {
                Button(isClosed ? "Reopen Account" : "Close Account", role: isClosed ? nil : .destructive) {
                    isClosed.toggle()
                    Task { await save() }
                }
            } message: {
                Text("The account's transactions, balance, reconciliation history, and reports are preserved.")
            }
        }
    }

    private var safeTypes: [String] {
        if account.isOnBudget { return ["checking", "savings", "cash"].contains(account.accountType) ? ["checking", "savings", "cash"] : [account.accountType] }
        return ["loan", "mortgage", "asset", "tracking"].contains(account.accountType) ? ["asset", "tracking", "loan", "mortgage"] : [account.accountType]
    }

    private func typeTitle(_ type: String) -> String {
        switch type { case "credit": "Credit Card"; case "loan": "Loan / Liability"; case "mortgage": "Mortgage"; case "asset": "Asset"; case "tracking": "Other Tracking"; default: type.capitalized }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await workspace.updateAccount(.init(accountID: account.id, name: name, currentKind: account.accountType, kind: accountType, isOnBudget: account.isOnBudget, isClosed: isClosed))
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AccountHistoryView: View {
    @EnvironmentObject private var workspace: BudgetWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let account: APIAccount
    @State private var items: [APIAccountRevision] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = false
    @State private var errorMessage: String?
    private let pageSize = 25

    var body: some View {
        NavigationStack {
            Group {
                if isLoading { ProgressView("Loading history…") }
                else if let errorMessage, items.isEmpty {
                    ContentUnavailableView("History unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(errorMessage))
                        .overlay(alignment: .bottom) { Button("Try Again") { Task { await load(reset: true) } }.buttonStyle(.borderedProminent).padding() }
                } else if items.isEmpty {
                    ContentUnavailableView("No account changes", systemImage: "clock",
                                           description: Text("Changes to this account will appear here."))
                } else {
                    List {
                        if let errorMessage {
                            Section {
                                Text(errorMessage).foregroundStyle(.secondary)
                                Button("Retry Earlier Changes") { Task { await load(reset: false) } }
                                    .disabled(isLoadingMore)
                            }
                        }
                        ForEach(items) { revision in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title(revision)).font(.headline)
                                if let detail = detail(revision) { Text(detail).font(.subheadline) }
                                Text("\(revision.actorDisplayName ?? "Unknown member") · \(revision.createdAt)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if hasMore {
                            Button(isLoadingMore ? "Loading…" : "Load Earlier Changes") {
                                Task { await load(reset: false) }
                            }.disabled(isLoadingMore)
                        }
                    }
                }
            }
            .navigationTitle("Account History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load(reset: true) }
        }
    }

    private func load(reset: Bool) async {
        guard !isLoading, !isLoadingMore, reset || hasMore else { return }
        errorMessage = nil
        if reset { isLoading = true; errorMessage = nil } else { isLoadingMore = true }
        defer { isLoading = false; isLoadingMore = false }
        do {
            let next = try await workspace.accountHistory(accountID: account.id, limit: pageSize,
                                                          offset: reset ? 0 : items.count)
            if reset { items = next } else { items.append(contentsOf: next) }
            hasMore = next.count == pageSize
        } catch { errorMessage = error.localizedDescription }
    }

    private func title(_ revision: APIAccountRevision) -> String {
        guard revision.action != "created", let before = revision.beforeSnapshot else { return "Account created" }
        if before.isClosed != revision.afterSnapshot.isClosed { return revision.afterSnapshot.isClosed ? "Account closed" : "Account reopened" }
        if before.name != revision.afterSnapshot.name { return "Account renamed" }
        if before.accountType != revision.afterSnapshot.accountType { return "Account type changed" }
        return "Account updated"
    }

    private func detail(_ revision: APIAccountRevision) -> String? {
        guard let before = revision.beforeSnapshot else { return revision.afterSnapshot.name }
        if before.name != revision.afterSnapshot.name { return "\(before.name) → \(revision.afterSnapshot.name)" }
        if before.accountType != revision.afterSnapshot.accountType { return "\(before.accountType.capitalized) → \(revision.afterSnapshot.accountType.capitalized)" }
        return nil
    }
}

/// Presentation of authoritative snapshots, never a projection or accounting calculation.
enum DelegatedPolicyHistoryPresentation {
    struct Change: Identifiable, Equatable {
        let id: String
        let label: String
        let before: String?
        let after: String?
    }
    static func changes(_ revision: APIDelegatedPolicyRevision, formatMoney: (Int64) -> String,
                        categoryName: (String) -> String) -> [Change] {
        let before = revision.beforeSnapshot, after = revision.afterSnapshot
        var result: [Change] = []
        func append(_ id: String, _ label: String, _ old: String?, _ new: String?, changed: Bool) {
            if changed { result.append(.init(id: id, label: label, before: old, after: new)) }
        }
        append("pool", "Authority pool", before.map { categoryName($0.poolCategoryID) }, categoryName(after.poolCategoryID),
               changed: before?.poolCategoryID != after.poolCategoryID)
        append("authority", "Authority limit", before.map { formatMoney($0.authorityMinor) }, formatMoney(after.authorityMinor),
               changed: before?.authorityMinor != after.authorityMinor)
        append("create", "Create categories", before.map { $0.allowCategoryCreation ? "Allowed" : "Not allowed" },
               after.allowCategoryCreation ? "Allowed" : "Not allowed", changed: before?.allowCategoryCreation != after.allowCategoryCreation)
        append("move", "Move money", before.map { $0.allowReallocation ? "Allowed" : "Not allowed" },
               after.allowReallocation ? "Allowed" : "Not allowed", changed: before?.allowReallocation != after.allowReallocation)
        func describe(_ rule: APIDelegatedPolicyRuleSnapshot?) -> String? {
            guard let rule else { return nil }
            var parts = [rule.ruleKind.replacingOccurrences(of: "_", with: " ").capitalized]
            if let minimum = rule.minimumMinor { parts.append("Minimum \(formatMoney(minimum))") }
            if let maximum = rule.maximumMinor { parts.append("Maximum \(formatMoney(maximum))") }
            return parts.joined(separator: " · ")
        }
        let ids = Set((before?.rules ?? []).map(\.categoryID) + after.rules.map(\.categoryID)).sorted()
        for id in ids {
            let old = before?.rules.first { $0.categoryID == id }, new = after.rules.first { $0.categoryID == id }
            append("rule-\(id)", categoryName(id), describe(old), describe(new), changed: old != new)
        }
        return result
    }
}

enum AllowanceHistoryPresentation {
    struct Change: Identifiable, Equatable {
        let id: String
        let label: String
        let before: String?
        let after: String?
    }
    static func changes(_ revision: APIAllowancePlanRevision, formatMoney: (Int64) -> String,
                        categoryName: (String) -> String, memberName: (String) -> String) -> [Change] {
        func values(_ snapshot: APIAllowancePlanRevisionSnapshot?) -> [String?] {
            guard let snapshot else { return Array(repeating: nil, count: 9) }
            return [snapshot.name, snapshot.delegatedUserID, snapshot.sourceCategoryID,
                    String(snapshot.amountMinor), snapshot.nextIssueDate, snapshot.recurrenceUnit.capitalized,
                    String(snapshot.intervalCount), snapshot.rolloverPolicy == "rollover" ? "Carries forward" : "Returns before next issue",
                    snapshot.isActive ? "Active" : "Paused"]
        }
        let old = values(revision.beforeSnapshot), new = values(revision.afterSnapshot)
        let labels = ["Name", "Recipient", "Source category", "Amount", "Next issue", "Recurrence", "Interval", "Unused money", "Status"]
        func display(_ value: String, index: Int) -> String {
            switch index {
            case 1: memberName(value)
            case 2: categoryName(value)
            case 3: Int64(value).map(formatMoney) ?? "Unavailable"
            default: value
            }
        }
        var result = labels.indices.compactMap { index -> Change? in
            guard old[index] != new[index] else { return nil }
            return .init(id: "field-\(index)", label: labels[index], before: old[index].map { display($0, index: index) },
                         after: new[index].map { display($0, index: index) })
        }
        let beforeSplits = revision.beforeSnapshot?.splits ?? [], afterSplits = revision.afterSnapshot.splits
        for id in Set(beforeSplits.map(\.destinationCategoryID) + afterSplits.map(\.destinationCategoryID)).sorted() {
            let before = beforeSplits.first { $0.destinationCategoryID == id }?.amountMinor
            let after = afterSplits.first { $0.destinationCategoryID == id }?.amountMinor
            if before != after {
                result.append(.init(id: "split-\(id)", label: "Destination: \(categoryName(id))",
                                    before: before.map(formatMoney), after: after.map(formatMoney)))
            }
        }
        return result
    }
}

enum ScheduleHistoryPresentation {
    struct Change: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let before: String?
        let after: String?
    }
    static func changes(_ revision: APIScheduledTransactionRevision, currencyCode: String,
                        locale: Locale = .current, hideAmounts: Bool = false,
                        accountName: (String) -> String = { _ in "Account" },
                        categoryName: (String) -> String = { _ in "Category" },
                        payeeName: (String) -> String = { _ in "Payee" }) -> [Change] {
        func values(_ snapshot: APIScheduledTransactionSnapshot?) -> [String?] {
            guard let snapshot else { return Array(repeating: nil, count: 15) }
            return [snapshot.name, snapshot.accountID, snapshot.destinationAccountID,
                    snapshot.categoryID, snapshot.payeeID,
                    CurrencyText.display(snapshot.amountMinor, currencyCode: currencyCode, locale: locale),
                    snapshot.nextDate, snapshot.recurrenceUnit.capitalized, String(snapshot.intervalCount),
                    snapshot.endDate, snapshot.remainingOccurrences.map(String.init), snapshot.memo,
                    snapshot.financialClassification?.replacingOccurrences(of: "_", with: " ").capitalized,
                    snapshot.isActive ? "Active" : "Paused", snapshot.lastRealizedOn]
        }
        let labels = ["Name", "Account", "Transfer destination", "Category", "Payee", "Amount",
                      "Next date", "Recurrence", "Interval", "End date", "Remaining entries", "Memo",
                      "Classification", "Status", "Last entered"]
        let before = values(revision.beforeSnapshot), after = values(revision.afterSnapshot)
        return labels.indices.compactMap { index in
            guard before[index] != after[index] else { return nil }
            let hidden = hideAmounts && index == 5
            func display(_ value: String) -> String {
                if hidden { return "••••" }
                switch index {
                case 1, 2: return accountName(value)
                case 3: return categoryName(value)
                case 4: return payeeName(value)
                default: return value
                }
            }
            return .init(label: labels[index], before: before[index].map(display), after: after[index].map(display))
        }
    }
}

enum TargetHistoryPresentation {
    struct Change: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let before: String?
        let after: String?
    }
    static func changes(_ revision: APICategoryTargetRevision, currencyCode: String,
                        locale: Locale = .current, hideAmounts: Bool = false) -> [Change] {
        func values(_ snapshot: APICategoryTargetSnapshot?) -> [String?] {
            guard let snapshot else { return Array(repeating: nil, count: 7) }
            return [snapshot.targetType.replacingOccurrences(of: "_", with: " ").capitalized,
                    CurrencyText.display(snapshot.targetAmountMinor, currencyCode: currencyCode, locale: locale),
                    snapshot.targetDate, snapshot.recurrenceMonths.map { "Every \($0) month\($0 == 1 ? "" : "s")" },
                    CurrencyText.display(snapshot.minimumContributionMinor, currencyCode: currencyCode, locale: locale),
                    String(snapshot.priority), snapshot.isActive ? "Active" : "Inactive"]
        }
        let labels = ["Target type", "Target amount", "Goal date", "Recurrence", "Minimum contribution", "Priority", "Status"]
        let before = values(revision.beforeSnapshot), after = values(revision.afterSnapshot)
        var changes = labels.indices.compactMap { index -> Change? in
            guard before[index] != after[index] else { return nil }
            let hidden = hideAmounts && [1, 4].contains(index)
            return .init(label: labels[index], before: before[index].map { hidden ? "••••" : $0 },
                         after: after[index].map { hidden ? "••••" : $0 })
        }
        if let month = revision.affectedMonth, ["snoozed", "resumed"].contains(revision.action) {
            let snoozed = revision.action == "snoozed"
            changes.append(.init(label: "Guidance for \(month)", before: snoozed ? "Active" : "Snoozed",
                                 after: snoozed ? "Snoozed" : "Active"))
        }
        return changes
    }
}

enum DebtTermsHistoryPresentation {
    struct Change: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let before: String?
        let after: String?
    }

    static func changes(_ revision: APIAccountDebtTermsRevision, currencyCode: String,
                        locale: Locale = .current, hideAmounts: Bool = false) -> [Change] {
        func percent(_ value: Int?) -> String? {
            value.map { NSDecimalNumber(value: $0).dividing(by: 100).stringValue + "%" }
        }
        func money(_ value: Int64?) -> String? {
            value.map { CurrencyText.display($0, currencyCode: currencyCode, locale: locale) }
        }
        func title(_ value: String?) -> String? {
            value?.replacingOccurrences(of: "_", with: " ").capitalized
        }
        func values(_ snapshot: APIAccountDebtTermsRevisionSnapshot?) -> [String?] {
            guard let snapshot else { return Array(repeating: nil, count: 15) }
            return [
                title(snapshot.termsType), percent(snapshot.annualRateBasisPoints), title(snapshot.rateType),
                title(snapshot.paymentFrequency), money(snapshot.scheduledPaymentMinor),
                title(snapshot.minimumPaymentRule), money(snapshot.minimumPaymentMinor),
                percent(snapshot.minimumPaymentRateBasisPoints), snapshot.dueDay.map(String.init),
                snapshot.statementDay.map(String.init), money(snapshot.originalPrincipalMinor),
                snapshot.originalTermMonths.map { "\($0) months" },
                snapshot.remainingTermMonths.map { "\($0) months" },
                percent(snapshot.promotionalRateBasisPoints), snapshot.promotionalEndsOn,
            ]
        }
        let labels = ["Terms type", "APR", "Rate type", "Payment frequency", "Scheduled payment",
                      "Minimum payment rule", "Minimum payment", "Minimum balance percentage",
                      "Payment due day", "Statement closing day", "Original principal", "Original term",
                      "Remaining term", "Promotional APR", "Promotional end date"]
        let before = values(revision.beforeSnapshot), after = values(revision.afterSnapshot)
        return labels.indices.compactMap { index in
            guard before[index] != after[index] else { return nil }
            let hidden = hideAmounts && [4, 6, 10].contains(index)
            return Change(label: labels[index], before: before[index].map { hidden ? "••••" : $0 },
                          after: after[index].map { hidden ? "••••" : $0 })
        }
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
    @State private var history: [APIAccountDebtTermsRevision] = []
    @State private var hasMoreHistory = false
    @State private var isLoadingHistory = false
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
                Section("Change history") {
                    ForEach(history) { revision in
                        DisclosureGroup {
                            ForEach(DebtTermsHistoryPresentation.changes(revision, currencyCode: currencyCode, hideAmounts: workspace.hideAmounts)) { change in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(change.label).font(.subheadline.weight(.medium))
                                    LabeledContent("Before", value: change.before ?? "Not set")
                                    LabeledContent("After", value: change.after ?? "Not set")
                                }
                                .font(.caption)
                                .accessibilityElement(children: .combine)
                            }
                            Text("Planning assumptions only. No posted balance was changed.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.action == "created" ? "Terms added" : revision.action == "deleted" ? "Terms removed" : "Terms updated")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(revision.actorDisplayName ?? "Household member") · \(formattedTimestamp(revision.createdAt))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("debt-history-\(revision.id)")
                    }
                    if history.isEmpty {
                        Text("Changes to these planning assumptions will appear here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if hasMoreHistory {
                        Button("Load Earlier Changes") { Task { await loadEarlierHistory() } }
                            .disabled(isLoadingHistory)
                    }
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
            async let stored = workspace.accountDebtTerms(accountID: account.id)
            async let revisions = workspace.accountDebtTermsHistory(accountID: account.id, limit: 10)
            history = try await revisions
            hasMoreHistory = history.count == 10
            guard let value = try await stored else { return }
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

    private func formattedTimestamp(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadEarlierHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let next = try await workspace.accountDebtTermsHistory(accountID: account.id, limit: 10, offset: history.count)
            history.append(contentsOf: next)
            hasMoreHistory = next.count == 10
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
