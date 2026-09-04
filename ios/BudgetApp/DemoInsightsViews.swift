import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var store: DemoStore
    let showProfile: () -> Void
    @State private var range = "6M"
    var body: some View {
        List {
            Section { Picker("Range",selection:$range){ForEach(["3M","6M","12M"],id:\.self){Text($0)}}.pickerStyle(.segmented).listRowInsets(EdgeInsets()) }
            Section("Spending & income") {
                NavigationLink { SpendingInsightView() } label: { InsightRow(icon:"chart.pie.fill",title:"Spending breakdown",value:"Where did our money go?",color:Theme.accent) }
                NavigationLink { IncomeSpendingView() } label: { InsightRow(icon:"chart.bar.xaxis",title:"Income vs. spending",value:"Average margin +$1,208",color:Theme.healthy) }
            }
            Section("Progress") {
                NavigationLink { NetWorthView() } label: { InsightRow(icon:"chart.line.uptrend.xyaxis",title:"Net worth",value:store.money(store.netWorth),color:Theme.healthy) }
                NavigationLink { GoalProgressView() } label: { InsightRow(icon:"target",title:"Goals",value:"4 active goals",color:Theme.accent) }
                NavigationLink { DebtPayoffView(accountID:"auto") } label: { InsightRow(icon:"arrow.down.right.circle.fill",title:"Debt progress",value:"Explore payoff options",color:Theme.attention) }
            }
            Section("Looking ahead") {
                NavigationLink { ForecastView() } label: { InsightRow(icon:"waveform.path.ecg",title:"Cash outlook",value:"30 days to 1 year",color:Theme.projected) }
                NavigationLink { PlanCostView() } label: { InsightRow(icon:"list.bullet.clipboard.fill",title:"Monthly plan",value:"What does our planned life cost?",color:Theme.accent) }
            }
            if !store.isRestricted { Section("Household") { NavigationLink { HouseholdInsightView() } label: { InsightRow(icon:"person.3.fill",title:"Household insights",value:"Allowances, requests, and member activity",color:Theme.accent) } } }
        }.navigationTitle("Insights").toolbar{ToolbarItem(placement:.topBarLeading){ProfileButton(action:showProfile)}}
    }
}

private struct InsightRow:View{let icon:String;let title:String;let value:String;let color:Color;var body:some View{HStack(spacing:14){Image(systemName:icon).font(.title2).foregroundStyle(color).frame(width:34);VStack(alignment:.leading,spacing:3){Text(title).fontWeight(.semibold);Text(value).font(.caption).foregroundStyle(.secondary)}}.padding(.vertical,5).accessibilityElement(children:.combine)}}

struct SpendingInsightView:View{
    @EnvironmentObject private var store:DemoStore
    var totals:[(String,Int64)]{let data=Dictionary(grouping:store.categories,by:\.group).mapValues{$0.reduce(0){$0+abs($1.activity)}};return data.sorted{$0.value>$1.value}.prefix(6).map{$0}}
    var body: some View {
        List {
            Section {
                Chart(totals, id: \.0) { item in
                    SectorMark(angle: .value("Spending", item.1), innerRadius: .ratio(0.58), angularInset: 2).foregroundStyle(by: .value("Group", item.0))
                }.frame(height: 260).chartLegend(.hidden).accessibilityLabel("Spending breakdown by category group")
            }
            Section("By category group") {
                ForEach(totals, id: \.0) { item in
                    LabeledContent(item.0) {
                        VStack(alignment: .trailing) {
                            MoneyText(amount: item.1)
                            Text("\(Int(Double(item.1) / Double(max(totals.reduce(0) { $0 + $1.1 }, 1)) * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("Spending Breakdown")
    }
}

struct IncomeSpendingView:View{
    @EnvironmentObject private var store:DemoStore
    var months:[String]{["Apr","May","Jun","Jul","Aug","Sep"]}
    var body: some View {
        List {
            Section {
                Chart(Array(months.enumerated()), id: \.offset) { index, month in
                    BarMark(x: .value("Month", month), y: .value("Amount", Double(store.incomeHistory[index]) / 100)).foregroundStyle(Theme.healthy).position(by: .value("Type", "Income"))
                    BarMark(x: .value("Month", month), y: .value("Amount", Double(store.spendingHistory[index]) / 100)).foregroundStyle(Theme.accent).position(by: .value("Type", "Spending"))
                }.frame(height: 260).chartYAxis(store.hideAmounts ? .hidden : .automatic).accessibilityLabel(store.hideAmounts ? "Income versus spending chart, amounts hidden" : "Income versus spending for six months")
            }
            Section("Six-month average") {
                LabeledContent("Income") { MoneyText(amount: store.incomeHistory.reduce(0,+) / 6) }
                LabeledContent("Spending") { MoneyText(amount: store.spendingHistory.reduce(0,+) / 6) }
                LabeledContent("Margin") { MoneyText(amount: (store.incomeHistory.reduce(0,+) - store.spendingHistory.reduce(0,+)) / 6) }
            }
        }.navigationTitle("Income vs. Spending")
    }
}

struct NetWorthView:View{
    @EnvironmentObject private var store:DemoStore
    var body: some View {
        List {
            Section {
                Chart(Array(store.netWorthHistory.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Month", index), y: .value("Net Worth", Double(value) / 100)).foregroundStyle(Theme.healthy)
                    AreaMark(x: .value("Month", index), y: .value("Net Worth", Double(value) / 100)).foregroundStyle(Theme.healthy.opacity(0.12))
                }.frame(height: 260).chartYAxis(store.hideAmounts ? .hidden : .automatic).accessibilityLabel(store.hideAmounts ? "Net worth chart, amounts hidden" : "Net worth increased over the last six months")
            }
            Section("Current") {
                LabeledContent("Assets") { MoneyText(amount: store.accounts.filter { $0.balance > 0 }.reduce(0) { $0 + $1.balance }) }
                LabeledContent("Liabilities") { MoneyText(amount: store.accounts.filter { $0.balance < 0 }.reduce(0) { $0 + $1.balance }) }
                LabeledContent("Net worth") { MoneyText(amount: store.netWorth) }
            }
        }.navigationTitle("Net Worth")
    }
}

struct GoalProgressView:View{
    @EnvironmentObject private var store:DemoStore
    var goals:[DemoCategory]{store.visibleCategories.filter{$0.group=="Goals" || $0.name.contains("Goal")}}
    var body:some View{List{ForEach(goals){goal in NavigationLink{CategoryDetailView(categoryID:goal.id)}label:{VStack(alignment:.leading,spacing:8){HStack{Label(goal.name,systemImage:goal.icon);Spacer();Text("\(Int(goal.progress*100))%").fontWeight(.semibold)};ProgressView(value:goal.progress).tint(Theme.healthy);if let date=goal.targetDate{Text("Projected target · \(date)").font(.caption).foregroundStyle(.secondary)}}.padding(.vertical,5)}}}.navigationTitle("Goal Progress")}
}

struct DebtPayoffView:View{
    @EnvironmentObject private var store:DemoStore;let accountID:String;@State private var extra=100.0
    var account:DemoAccount{store.accounts.first(where:{$0.id==accountID})!};var principal:Double{Double(abs(account.balance))/100};var rate:Double{(account.apr ?? 0)/1200};var payment:Double{Double(account.minimumPayment ?? 0)/100+extra}
    var months:Int{guard payment>principal*rate else{return 999};return Int(ceil(-log(1-principal*rate/payment)/log(1+rate)))}
    var baseMonths:Int{let p=Double(account.minimumPayment ?? 0)/100;guard p>principal*rate else{return 999};return Int(ceil(-log(1-principal*rate/p)/log(1+rate)))}
    var interest:Double{max(payment*Double(months)-principal,0)}
    var body: some View {
        List {
            Section { VStack(spacing:6) { Text("PROJECTED PAYOFF").font(.caption.bold()).foregroundStyle(.secondary); Text(Calendar.current.date(byAdding:.month,value:months,to:Date())?.formatted(.dateTime.month(.wide).year()) ?? "—").font(.system(size:30,weight:.bold,design:.rounded)); Text("\(max(baseMonths-months,0)) months sooner").foregroundStyle(Theme.healthy) }.frame(maxWidth:.infinity).padding() }
            Section("What if?") { LabeledContent("Extra each month") { Text("$\(Int(extra))") }; Slider(value:$extra,in:0...500,step:25).tint(Theme.accent) }
            Section("Projection") { LabeledContent("Current principal") { MoneyText(amount:abs(account.balance)) }; LabeledContent("Monthly payment",value:(Int64(payment*100)).demoCurrency); LabeledContent("Interest remaining",value:(Int64(interest*100)).demoCurrency); LabeledContent("Projected payments",value:"\(months)") }
            Section { Text("Estimate uses the current principal, APR, and a fixed monthly payment. It is planning guidance, not a lender quote.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("\(account.name) Payoff")
    }
}

struct ForecastView:View{
    @EnvironmentObject private var store:DemoStore;@State private var horizon="30 Days"
    let horizons=["30 Days","60 Days","90 Days","6 Months","1 Year"]
    var factor:Int64{Int64((horizons.firstIndex(of:horizon) ?? 0)+1)}
    var points:[DemoForecastPoint]{[.init(label:"Today",value:744032,isActual:true),.init(label:"Payday",value:1119032,isActual:false),.init(label:"Mortgage",value:934532,isActual:false),.init(label:"Bills",value:812300-factor*4200,isActual:false),.init(label:"Low",value:523400-factor*7600,isActual:false)]}
    var body: some View {
        List {
            Section { Picker("Horizon", selection: $horizon) { ForEach(horizons, id: \.self) { Text($0) } }.pickerStyle(.menu) }
            Section {
                Chart(points) { point in
                    LineMark(x: .value("Point", point.label), y: .value("Cash", Double(point.value) / 100)).foregroundStyle(point.isActual ? Theme.healthy : Theme.projected).lineStyle(StrokeStyle(dash: point.isActual ? [] : [5]))
                    PointMark(x: .value("Point", point.label), y: .value("Cash", Double(point.value) / 100)).foregroundStyle(point.isActual ? Theme.healthy : Theme.projected)
                }.frame(height: 240).chartYAxis(store.hideAmounts ? .hidden : .automatic).accessibilityLabel(store.hideAmounts ? "Projected cash outlook, amounts hidden" : "Projected cash outlook with expected income and expenses")
            }
            Section("Projected summary") {
                LabeledContent("Projected cash") { MoneyText(amount: points.last!.value) }
                LabeledContent("Lowest projected point") { MoneyText(amount: points.map(\.value).min()!) }
                LabeledContent("Expected income") { MoneyText(amount: 750000) }
                LabeledContent("Funding obligations") { MoneyText(amount: -642000) }
                StatusLabel(title: "No projected shortfall", systemImage: "checkmark.circle.fill", color: Theme.healthy)
            }
            Section("Upcoming") {
                Label("Mortgage · Oct 1 · \(store.money(-184500))", systemImage: "house.fill")
                Label("Auto payment · Oct 1 · \(store.money(-41200))", systemImage: "car.fill")
                Label("Targets at risk · Dining Out", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
            }
            Section { Text("Projected values are estimates from scheduled activity and targets. They are visually dashed and never included in current available money.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Cash Outlook")
    }
}

struct PlanCostView:View{
    @EnvironmentObject private var store:DemoStore
    var body: some View {
        List {
            Section { VStack(spacing:7) { Text("MONTHLY PLANNED COST").font(.caption.bold()).foregroundStyle(.secondary); MoneyText(amount:642000,style:.system(size:36,weight:.bold,design:.rounded)); Text("Expected income \(store.money(725000))"); StatusLabel(title:"\(store.money(83000)) monthly margin",systemImage:"arrow.up.circle.fill",color:Theme.healthy) }.frame(maxWidth:.infinity).padding() }
            Section("Plan breakdown") { PlanCostRow(title:"Required",amount:373000,total:642000,color:Theme.accent); PlanCostRow(title:"True expenses",amount:97000,total:642000,color:.blue); PlanCostRow(title:"Goals",amount:112000,total:642000,color:Theme.healthy); PlanCostRow(title:"Discretionary",amount:60000,total:642000,color:Theme.attention) }
        }.navigationTitle("Monthly Plan")
    }
}
private struct PlanCostRow:View{let title:String;let amount:Int64;let total:Int64;let color:Color;var body:some View{VStack(alignment:.leading){HStack{Text(title);Spacer();MoneyText(amount:amount)};ProgressView(value:Double(amount),total:Double(total)).tint(color)}}}

struct HouseholdInsightView:View{
    @EnvironmentObject private var store:DemoStore
    var body: some View {
        List {
            Section("This month") { LabeledContent("Household spending") { MoneyText(amount:634000) }; LabeledContent("Allowances issued") { MoneyText(amount:12800) }; LabeledContent("Requests approved",value:"2 of 3"); LabeledContent("Savings progress",value:"73% on track") }
            Section("Member activity") { ForEach(DemoPersona.allCases) { person in LabeledContent(person.rawValue,value:"\(store.transactions.filter{$0.member==person}.count) entries") } }
        }.navigationTitle("Household Insights")
    }
}
