import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ActivityView: View {
    @EnvironmentObject private var store: DemoStore
    let showProfile: () -> Void
    @State private var search = ""
    @State private var filter = "All"
    @State private var showingAdd = false

    var results: [DemoTransaction] {
        store.visibleTransactions.filter { transaction in
            let account = store.accounts.first(where: { $0.id == transaction.accountID })?.name ?? ""
            let searchable = [transaction.payee, transaction.memo, account, transaction.member.rawValue, transaction.amount.demoCurrency, transaction.date.formatted(date:.abbreviated,time:.omitted), transaction.flag ?? ""]
            let matchesSearch = search.isEmpty || searchable.contains { $0.localizedCaseInsensitiveContains(search) } || transaction.categoryIDs.contains { id in store.categories.first(where:{$0.id == id})?.name.localizedCaseInsensitiveContains(search) == true }
            let matchesFilter = filter == "All" || (filter == "Uncleared" && !transaction.cleared) || (filter == "Scheduled" && transaction.scheduled) || (filter == "Flagged" && transaction.flag != nil)
            return matchesSearch && matchesFilter
        }
    }

    var body: some View {
        List {
            Section { Picker("Filter",selection:$filter) { ForEach(["All","Uncleared","Scheduled","Flagged"],id:\.self){Text($0)} }.pickerStyle(.segmented).listRowInsets(EdgeInsets()) }
            if results.isEmpty { ContentUnavailableView.search(text:search) }
            ForEach(Dictionary(grouping:results,by:{Calendar.current.startOfDay(for:$0.date)}).keys.sorted(by:>),id:\.self) { date in
                Section(date.formatted(date:.abbreviated,time:.omitted)) {
                    ForEach(results.filter{Calendar.current.isDate($0.date,inSameDayAs:date)}) { transaction in TransactionRow(transaction:transaction) }
                }
            }
        }
        .searchable(text:$search,prompt:"Payee, memo, category, amount")
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement:.topBarLeading){ProfileButton(action:showProfile)}
            ToolbarItem(placement:.topBarTrailing){Button{showingAdd=true}label:{Image(systemName:"plus")}.accessibilityLabel("Add transaction")}
        }.sheet(isPresented:$showingAdd){TransactionEntrySheet()}
    }
}

struct TransactionRow: View {
    @EnvironmentObject private var store: DemoStore
    let transaction: DemoTransaction
    var categoryNames: String { transaction.categoryIDs.compactMap{id in store.categories.first(where:{$0.id==id})?.name}.joined(separator:", ") }
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:transaction.amount > 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title3).foregroundStyle(transaction.amount > 0 ? Theme.healthy : Theme.accent)
            VStack(alignment:.leading,spacing:3) {
                HStack { Text(transaction.payee).fontWeight(.medium); if transaction.attachmentName != nil { Image(systemName:"paperclip").font(.caption).foregroundStyle(.secondary) } }
                Text(categoryNames.isEmpty ? transaction.memo : categoryNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:3) {
                MoneyText(amount:transaction.amount,style:.subheadline.weight(.semibold))
                Image(systemName:transaction.cleared ? "c.circle.fill" : "c.circle").font(.caption).foregroundStyle(transaction.cleared ? Theme.healthy : .secondary).accessibilityLabel(transaction.cleared ? "Cleared" : "Uncleared")
            }
        }.accessibilityElement(children:.combine)
    }
}

struct TransactionEntrySheet: View {
    @EnvironmentObject private var store: DemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = "125.00"
    @State private var payee = "Fresh Market"
    @State private var memo = "Weekly groceries"
    @State private var account = "visa"
    @State private var selectedCategories: Set<String> = ["groceries"]
    @State private var split = false
    @State private var photoItem: PhotosPickerItem?
    @State private var hasAttachment = false
    @State private var showingFiles = false

    var minor: Int64 { Int64((Double(amount) ?? 0) * 100) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type",selection:.constant("Expense")){Text("Expense").tag("Expense");Text("Income").tag("Income");Text("Transfer").tag("Transfer")}.pickerStyle(.segmented)
                    HStack { Text("$").foregroundStyle(.secondary); TextField("0.00",text:$amount).keyboardType(.decimalPad).font(.system(size:34,weight:.bold,design:.rounded)).monospacedDigit() }
                }
                Section {
                    TextField("Payee",text:$payee)
                    Picker("Account",selection:$account){ForEach(store.visibleAccounts.filter{$0.kind != .loan && $0.kind != .mortgage && $0.kind != .asset}){Text($0.name).tag($0.id)}}
                    Toggle("Split transaction",isOn:$split)
                    if split {
                        ForEach(store.visibleCategories.prefix(8)) { category in Toggle(category.name,isOn:Binding(get:{selectedCategories.contains(category.id)},set:{value in if value {selectedCategories.insert(category.id)} else {selectedCategories.remove(category.id)}})) }
                    } else {
                        Picker("Category",selection:Binding(get:{selectedCategories.first ?? "groceries"},set:{selectedCategories=[$0]})){ForEach(store.visibleCategories){Text($0.name).tag($0.id)}}
                    }
                    TextField("Memo",text:$memo)
                }
                Section("Receipt") {
                    PhotosPicker(selection:$photoItem,matching:.images){Label(hasAttachment ? "Photo selected" : "Photo Library",systemImage:"photo")}
                    Button("Choose File",systemImage:"folder"){showingFiles=true}
                    Label("Camera available on a physical iPhone",systemImage:"camera").foregroundStyle(.secondary)
                }
            }.navigationTitle("New Transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}
                ToolbarItem(placement:.confirmationAction){Button("Save"){store.addTransaction(payee:payee,amount:minor,accountID:account,categoryIDs:Array(selectedCategories),memo:memo,attachment:hasAttachment);dismiss()}.disabled(minor<=0 || payee.isEmpty || selectedCategories.isEmpty)}
            }
            .onChange(of:photoItem){_,item in hasAttachment = item != nil}
            .fileImporter(isPresented:$showingFiles,allowedContentTypes:[.image,.pdf]){result in if case .success = result {hasAttachment=true}}
        }
    }
}

struct AccountsView: View {
    @EnvironmentObject private var store: DemoStore
    let showProfile: () -> Void
    @State private var showingReconcile = false
    var grouped: [(String,[DemoAccount])] {
        let order = ["Cash Accounts","Credit Cards","Loans & Debt","Tracking Assets"]
        return order.compactMap { title in let values=store.visibleAccounts.filter{$0.kind.title==title}; return values.isEmpty ? nil : (title,values) }
    }
    var body: some View {
        List {
            if !store.isRestricted {
                Section {
                    LabeledContent("Net worth") { MoneyText(amount:store.netWorth,style:.title2.bold()) }
                    Text("Cash, debt, and tracking accounts").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(grouped,id:\.0){group in Section(group.0){ForEach(group.1){account in NavigationLink{AccountDetailView(accountID:account.id)}label:{AccountRow(account:account)}}}}
        }.navigationTitle("Accounts").toolbar {
            ToolbarItem(placement:.topBarLeading){ProfileButton(action:showProfile)}
            if !store.isRestricted { ToolbarItem(placement:.topBarTrailing){Button("Reconcile"){showingReconcile=true}} }
        }.sheet(isPresented:$showingReconcile){ReconcileView(accountID:"checking")}
    }
}

struct AccountRow: View {
    @EnvironmentObject private var store: DemoStore
    let account: DemoAccount
    var body: some View { HStack(spacing:13){Image(systemName:account.kind.icon).foregroundStyle(Theme.accent).frame(width:28);VStack(alignment:.leading){Text(account.name);Text(account.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)};Spacer();MoneyText(amount:account.balance,style:.headline)}.padding(.vertical,4).accessibilityElement(children:.combine) }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: DemoStore
    let accountID: String
    @State private var showingReconcile=false
    var account:DemoAccount{store.accounts.first(where:{$0.id==accountID})!}
    var body:some View{List{
        Section{VStack(spacing:10){Image(systemName:account.kind.icon).font(.largeTitle).foregroundStyle(Theme.accent);MoneyText(amount:account.balance,style:.system(size:38,weight:.bold,design:.rounded));Text("Working balance").foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding()}
        if account.kind == .credit { Section("Payment plan"){LabeledContent("Reserved for payment"){MoneyText(amount:account.paymentReserved)};LabeledContent("New funded spending"){MoneyText(amount:account.fundedSpending)};LabeledContent("Unfunded card spending"){MoneyText(amount:account.unfundedSpending)};if let due=account.dueText{LabeledContent("Payment",value:due)};StatusLabel(title:"Budget money moves here as card spending is funded",systemImage:"arrow.triangle.2.circlepath",color:Theme.accent)} }
        if account.kind == .loan || account.kind == .mortgage { NavigationLink("Explore payoff options"){DebtPayoffView(accountID:accountID)} }
        Section("Balance"){LabeledContent("Cleared"){MoneyText(amount:account.cleared)};LabeledContent("Uncleared"){MoneyText(amount:account.balance-account.cleared)};if let apr=account.apr{LabeledContent("Interest rate",value:String(format:"%.2f%%",apr))}}
        Section("Activity"){ForEach(store.transactions.filter{$0.accountID==accountID}.prefix(10)){TransactionRow(transaction:$0)}}
    }.navigationTitle(account.name).navigationBarTitleDisplayMode(.inline).toolbar{if account.kind != .asset{Button("Reconcile"){showingReconcile=true}}}.sheet(isPresented:$showingReconcile){ReconcileView(accountID:accountID)}}
}

struct ReconcileView:View{
    @EnvironmentObject private var store:DemoStore;@Environment(\.dismiss)private var dismiss;let accountID:String;@State private var balance="6840.32"
    var actual:Int64{Int64((Double(balance) ?? 0)*100)};var account:DemoAccount{store.accounts.first(where:{$0.id==accountID})!}
    var body: some View {
        NavigationStack {
            Form {
                Section("Statement balance") { TextField("0.00", text: $balance).keyboardType(.decimalPad).font(.title) }
                Section("Comparison") {
                    LabeledContent("App cleared balance") { MoneyText(amount: account.cleared) }
                    LabeledContent("Difference") { MoneyText(amount: actual - account.cleared) }
                    Text("No adjustment is created unless you explicitly confirm it.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Reconcile").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Confirm") { dismiss() } }
            }
        }
    }
}
