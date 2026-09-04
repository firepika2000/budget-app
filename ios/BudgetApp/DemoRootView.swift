import SwiftUI
import Charts

struct DemoRootView: View {
    @StateObject private var store = DemoStore()
    @State private var selectedTab: Int
    @State private var showingProfile = false

    init() {
        let screen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-screen=") }?.split(separator: "=").last.map(String.init) ?? "home"
        _selectedTab = State(initialValue: ["home":0, "plan":1, "activity":2, "accounts":3, "insights":4][screen] ?? 0)
    }

    var body: some View {
        Group {
            if let detail = demoDetail {
                NavigationStack { detail }
            } else {
                tabs
            }
        }
        .tint(Theme.accent)
        .environmentObject(store)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showProfile: { showingProfile = true }, openPlan: { selectedTab = 1 }) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack { PlanView(showProfile: { showingProfile = true }) }
                .tabItem { Label("Plan", systemImage: "square.grid.2x2.fill") }.tag(1)
            NavigationStack { ActivityView(showProfile: { showingProfile = true }) }
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { AccountsView(showProfile: { showingProfile = true }) }
                .tabItem { Label("Accounts", systemImage: "wallet.bifold.fill") }.tag(3)
            NavigationStack { InsightsView(showProfile: { showingProfile = true }) }
                .tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }.tag(4)
        }
        .sheet(isPresented: $showingProfile) { HouseholdView() }
    }

    private var demoDetail: AnyView? {
        let screen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-screen=") }?.split(separator: "=").last.map(String.init)
        switch screen {
        case "category": return AnyView(CategoryDetailView(categoryID: "groceries"))
        case "transaction": return AnyView(TransactionEntryLauncher())
        case "credit": return AnyView(AccountDetailView(accountID: "visa"))
        case "goal": return AnyView(CategoryDetailView(categoryID: "cnc"))
        case "household": return AnyView(HouseholdView())
        case "child": return AnyView(ChildDemoLauncher())
        case "approval": return AnyView(RequestApprovalView(request: DemoStore.seedRequests[0]))
        case "forecast": return AnyView(ForecastView())
        default: return nil
        }
    }
}

private struct TransactionEntryLauncher: View {
    var body: some View { Text("Transaction Entry").hidden().sheet(isPresented: .constant(true)) { TransactionEntrySheet() } }
}

private struct ChildDemoLauncher: View {
    @EnvironmentObject private var store: DemoStore
    var body: some View { HomeView(showProfile: {}).onAppear { store.persona = .alex } }
}

enum Theme {
    static let accent = Color(red: 0.10, green: 0.40, blue: 0.36)
    static let healthy = Color(red: 0.12, green: 0.48, blue: 0.33)
    static let attention = Color(red: 0.80, green: 0.48, blue: 0.08)
    static let danger = Color(red: 0.74, green: 0.18, blue: 0.20)
    static let projected = Color.indigo
}

struct ProfileButton: View {
    @EnvironmentObject private var store: DemoStore
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(store.persona.initials)
                .font(.subheadline.bold()).frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.14), in: Circle())
                .accessibilityLabel("Household and profile, signed in as \(store.persona.rawValue)")
        }
    }
}

struct MoneyText: View {
    @EnvironmentObject private var store: DemoStore
    let amount: Int64
    var style: Font = .body
    var body: some View {
        Text(store.money(amount)).font(style).monospacedDigit()
            .accessibilityLabel(store.hideAmounts ? "Amount hidden" : amount.demoCurrency)
    }
}

struct StatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: DemoStore
    let showProfile: () -> Void
    var openPlan: () -> Void = {}
    @State private var showingAdd = false
    @State private var showingApproval = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.persona.isChild ? "Hi, \(store.persona.rawValue)" : "Good morning, \(store.persona.rawValue)")
                        .font(.largeTitle.bold())
                    Text(store.persona.isChild ? "Here’s what’s yours to use." : "The Soto Household · September")
                        .foregroundStyle(.secondary)
                }

                if store.persona.isChild { childSummary } else { ownerSummary }
                attentionSection
                if !store.persona.isChild { forecastCard }
                recentActivity
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ProfileButton(action: showProfile) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.hideAmounts.toggle() } label: {
                    Image(systemName: store.hideAmounts ? "eye.slash.fill" : "eye.fill")
                }.accessibilityLabel(store.hideAmounts ? "Show amounts" : "Hide amounts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel("Add transaction")
            }
        }
        .sheet(isPresented: $showingAdd) { TransactionEntrySheet() }
        .sheet(isPresented: $showingApproval) {
            if let request = store.pendingRequests.first { RequestApprovalView(request: request) }
        }
    }

    private var ownerSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AVAILABLE TO ASSIGN").font(.caption.bold()).foregroundStyle(.secondary)
            MoneyText(amount: store.readyToAssign, style: .system(size: 38, weight: .bold, design: .rounded))
            Text("New money waiting for a purpose").font(.subheadline).foregroundStyle(.secondary)
            Button("Make a plan", systemImage: "sparkles", action: openPlan)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private var childSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AVAILABLE TO SPEND").font(.caption.bold()).foregroundStyle(.secondary)
            MoneyText(amount: store.availableToSpend, style: .system(size: 38, weight: .bold, design: .rounded))
            ForEach(store.visibleCategories.filter { $0.target != nil }.prefix(2)) { category in
                VStack(alignment: .leading) {
                    HStack { Label(category.name, systemImage: category.icon); Spacer(); MoneyText(amount: category.available) }
                    ProgressView(value: category.progress).tint(Theme.healthy)
                }
            }
            if let allowance = store.allowances.first(where: { $0.member == store.persona }) {
                Label("Next allowance \(allowance.nextDate) · \(store.money(allowance.amount))", systemImage: "calendar.badge.clock")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs attention").font(.title2.bold())
            if !store.persona.isChild, let request = store.pendingRequests.first {
                Button { showingApproval = true } label: {
                    AttentionRow(icon:"hand.raised.fill", color:Theme.attention, title:"\(request.member.rawValue) requested \(store.money(request.amount))", subtitle:request.reason)
                }.buttonStyle(.plain)
            }
            ForEach(store.overspent.prefix(2)) { category in
                NavigationLink { CategoryDetailView(categoryID: category.id) } label: {
                    AttentionRow(icon:"exclamationmark.triangle.fill", color:Theme.danger, title:"\(category.name) is overspent", subtitle:"Cover \(store.money(abs(category.available)))")
                }.buttonStyle(.plain)
            }
            ForEach(store.underfunded.prefix(store.persona.isChild ? 2 : 1)) { category in
                NavigationLink { CategoryDetailView(categoryID: category.id) } label: {
                    AttentionRow(icon:"target", color:Theme.attention, title:"\(category.name) needs funding", subtitle:"\(Int(category.progress * 100))% of target")
                }.buttonStyle(.plain)
            }
        }
    }

    private var forecastCard: some View {
        NavigationLink { ForecastView() } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Label("30-day cash outlook", systemImage:"waveform.path.ecg").font(.headline); Spacer(); Image(systemName:"chevron.right") }
                Text("Projected low point").font(.caption).foregroundStyle(.secondary)
                MoneyText(amount: 523400, style: .title2.bold())
                StatusLabel(title:"No shortfall expected", systemImage:"checkmark.circle.fill", color:Theme.healthy)
            }.padding(16).background(Theme.projected.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent activity").font(.title2.bold())
            ForEach(store.visibleTransactions.prefix(4)) { transaction in TransactionRow(transaction: transaction) }
        }
    }
}

private struct AttentionRow: View {
    let icon: String; let color: Color; let title: String; let subtitle: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 28)
            VStack(alignment:.leading,spacing:2) { Text(title).fontWeight(.semibold); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

struct PlanView: View {
    @EnvironmentObject private var store: DemoStore
    let showProfile: () -> Void
    @State private var filter = "All"
    @State private var showingSmartFund = false
    @State private var showingMove = false
    @State private var showingGoal = false

    var filtered: [DemoCategory] {
        switch filter {
        case "Underfunded": store.visibleCategories.filter { $0.progress < 1 && $0.available >= 0 }
        case "Overspent": store.visibleCategories.filter { $0.available < 0 }
        case "Pinned": store.visibleCategories.filter(\.pinned)
        default: store.visibleCategories
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:8) {
                    Text(store.persona.isChild ? "YOUR PLAN" : "AVAILABLE TO ASSIGN").font(.caption.bold()).foregroundStyle(.secondary)
                    MoneyText(amount: store.persona.isChild ? store.availableToSpend : store.readyToAssign, style:.system(size:32,weight:.bold,design:.rounded))
                    if !store.persona.isChild {
                        HStack {
                            Button("Smart Fund", systemImage:"sparkles") { showingSmartFund = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button("Move", systemImage:"arrow.left.arrow.right") { showingMove = true }.buttonStyle(.bordered)
                        }
                    }
                }.padding(.vertical,8)
            }
            Section {
                Picker("View", selection:$filter) { ForEach(["All","Underfunded","Overspent","Pinned"],id:\.self) { Text($0) } }
                    .pickerStyle(.segmented).listRowInsets(EdgeInsets())
            }
            ForEach(Dictionary(grouping: filtered, by: \.group).keys.sorted(), id:\.self) { group in
                Section(group) {
                    ForEach(filtered.filter { $0.group == group }) { category in
                        NavigationLink { CategoryDetailView(categoryID:category.id) } label: { CategoryRow(category:category) }
                            .swipeActions(edge:.leading,allowsFullSwipe:false) {
                                if !store.persona.isChild { Button("Move",systemImage:"arrow.left.arrow.right") { showingMove = true }.tint(Theme.accent) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Plan")
        .toolbar {
            ToolbarItem(placement:.topBarLeading) { ProfileButton(action:showProfile) }
            ToolbarItem(placement:.principal) { Text(store.selectedMonth).font(.headline) }
            if !store.persona.isChild { ToolbarItem(placement:.topBarTrailing) { Button { showingGoal = true } label: { Image(systemName:"plus") }.accessibilityLabel("Create goal") } }
        }
        .sheet(isPresented:$showingSmartFund) { SmartFundingView() }
        .sheet(isPresented:$showingMove) { MoveMoneyView() }
        .sheet(isPresented:$showingGoal) { GoalCreationView() }
    }
}

struct GoalCreationView: View {
    @EnvironmentObject private var store: DemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "CNC Machine"
    @State private var amount = "2000"
    @State private var date = "June 2027"
    var minor: Int64 { Int64((Double(amount) ?? 0) * 100) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") { TextField("Name", text:$name); HStack { Text("$"); TextField("Amount",text:$amount).keyboardType(.decimalPad) }; TextField("Target date",text:$date) }
                Section { Text("This creates a planning target. It does not create money or change current availability.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("New Goal").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Create") { store.addGoal(name:name,amount:minor,targetDate:date);dismiss() }.disabled(name.isEmpty || minor <= 0) }
            }
        }
    }
}

struct CategoryRow: View {
    @EnvironmentObject private var store: DemoStore
    let category: DemoCategory
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack { Label(category.name,systemImage:category.icon); Spacer(); MoneyText(amount:category.available,style:.headline) }
            HStack {
                StatusLabel(title:category.status, systemImage:category.available < 0 ? "exclamationmark.triangle.fill" : category.progress < 1 ? "circle.dotted" : "checkmark.circle.fill", color:category.available < 0 ? Theme.danger : category.progress < 1 ? Theme.attention : Theme.healthy)
                Spacer(); Text("Assigned \(store.money(category.assigned))").font(.caption).foregroundStyle(.secondary)
            }
            if category.target != nil { ProgressView(value:category.progress).tint(category.available < 0 ? Theme.danger : Theme.healthy) }
        }.padding(.vertical,4).accessibilityElement(children:.combine)
    }
}

struct CategoryDetailView: View {
    @EnvironmentObject private var store: DemoStore
    let categoryID: String
    var category: DemoCategory { store.categories.first(where:{$0.id == categoryID})! }
    var body: some View {
        List {
            Section {
                VStack(spacing:16) {
                    Image(systemName:category.icon).font(.largeTitle).foregroundStyle(Theme.accent)
                    MoneyText(amount:category.available,style:.system(size:38,weight:.bold,design:.rounded))
                    Text("Available").foregroundStyle(.secondary)
                    if let target = category.target {
                        ProgressView(value:category.progress).tint(Theme.healthy)
                        Text("\(Int(category.progress * 100))% of \(store.money(target))").font(.subheadline)
                    }
                }.frame(maxWidth:.infinity).padding(.vertical,18)
            }
            Section("This month") {
                LabeledContent("Assigned") { MoneyText(amount:category.assigned) }
                LabeledContent("Activity") { MoneyText(amount:category.activity) }
                if let targetDate = category.targetDate { LabeledContent("Target date",value:targetDate) }
                LabeledContent("Status",value:category.status)
            }
            Section("Recent activity") {
                ForEach(store.transactions.filter{$0.categoryIDs.contains(categoryID)}.prefix(6)) { TransactionRow(transaction:$0) }
            }
            if !category.note.isEmpty { Section("Note") { Text(category.note) } }
        }.navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct SmartFundingView: View {
    @EnvironmentObject private var store: DemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var strategy = "Fund priorities"
    var proposals: [(DemoCategory,Int64)] {
        var remaining = store.readyToAssign
        var result: [(DemoCategory, Int64)] = []
        for category in store.categories.filter({ $0.target != nil && $0.progress < 1 && $0.available >= 0 }).prefix(6) {
            let amount = min((category.target ?? 0) - category.available, 60000, remaining)
            if amount > 0 { result.append((category, amount)); remaining -= amount }
        }
        return result
    }
    var total: Int64 { proposals.reduce(0){$0+$1.1} }
    var body: some View {
        NavigationStack {
            List {
                Section("Strategy") { Picker("Strategy",selection:$strategy) { ForEach(["Fund priorities","Due before payday","True expenses","Goals","Repeat last month"],id:\.self){Text($0)} } }
                Section("Preview — no changes yet") {
                    LabeledContent("Before") { MoneyText(amount:store.readyToAssign) }
                    LabeledContent("Proposed") { MoneyText(amount:-total) }
                    LabeledContent("After") { MoneyText(amount:store.readyToAssign-total) }
                }
                Section("Recommended allocations") {
                    ForEach(proposals,id:\.0.id) { item in LabeledContent(item.0.name) { MoneyText(amount:item.1) } }
                }
            }.navigationTitle("Smart Funding").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}
                ToolbarItem(placement:.confirmationAction){Button("Confirm") { for item in proposals { store.assign(amount:item.1,to:item.0.id) }; dismiss() }.disabled(total == 0)}
            }
        }
    }
}

struct MoveMoneyView: View {
    @EnvironmentObject private var store: DemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = "dining"
    @State private var destination = "fuel"
    @State private var amount = "50"
    var minor: Int64 { Int64((Double(amount) ?? 0) * 100) }
    var body: some View {
        NavigationStack { Form {
            Section("Move from") { Picker("Source",selection:$source){ForEach(store.visibleCategories){Text("\($0.name) · \(store.money($0.available))").tag($0.id)}} }
            Section("Move to") { Picker("Destination",selection:$destination){ForEach(store.visibleCategories){Text($0.name).tag($0.id)}} }
            Section("Amount") { TextField("0.00",text:$amount).keyboardType(.decimalPad).font(.title2).monospacedDigit() }
            Section("Preview") {
                if let from=store.categories.first(where:{$0.id==source}),let to=store.categories.first(where:{$0.id==destination}) {
                    LabeledContent("\(from.name) after"){MoneyText(amount:from.available-minor)}
                    LabeledContent("\(to.name) after"){MoneyText(amount:to.available+minor)}
                }
            }
        }.navigationTitle("Move Money").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}
            ToolbarItem(placement:.confirmationAction){Button("Confirm"){store.move(amount:minor,from:source,to:destination);dismiss()}.disabled(minor<=0 || source==destination)}
        }}
    }
}
