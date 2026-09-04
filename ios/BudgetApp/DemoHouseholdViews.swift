import SwiftUI

struct HouseholdView: View {
    @EnvironmentObject private var store: DemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingReset = false
    var body: some View {
        NavigationStack {
            List {
                householdHeader
                personas
                householdLinks
                privacy
                hosting
                resetActions
            }
            .navigationTitle("Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset all demo changes?", isPresented: $showingReset, titleVisibility: .visible) { Button("Reset Demo", role: .destructive) { store.reset() } }
        }
    }

    private var householdHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("The Soto Household").font(.title2.bold())
                Text("Demo environment · Local deterministic data").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }

    private var personas: some View {
        Section("View as") {
            ForEach(DemoPersona.allCases) { person in PersonaRow(person: person, selected: store.persona == person) {
                store.persona = person
                dismiss()
            } }
        }
    }

    @ViewBuilder private var householdLinks: some View {
        if store.isRestricted {
            Section("My household") {
                NavigationLink { RequestsView() } label: { Label("My requests", systemImage: "hand.raised.fill") }
                NavigationLink { AllowancesView() } label: { Label("My allowance", systemImage: "calendar.badge.clock") }
            }
        } else {
            Section("Household") {
                NavigationLink { MemberAccessView() } label: { Label("Members & access", systemImage: "person.3.fill") }
                NavigationLink { RequestsView() } label: { Label("Requests & approvals", systemImage: "hand.raised.fill") }
                NavigationLink { AllowancesView() } label: { Label("Recurring allowances", systemImage: "calendar.badge.clock") }
            }
        }
    }

    private var privacy: some View { Section("Privacy") { Toggle("Hide amounts", isOn: $store.hideAmounts); Text("Hides financial values throughout every demo screen.").font(.footnote).foregroundStyle(.secondary) } }
    private var hosting: some View { Section("Self-hosting") { LabeledContent("Server", value: "Demo · On device"); Label("Production connects only to your chosen server", systemImage: "lock.shield.fill"); Label("No bank connections in v0.3.0", systemImage: "building.columns") } }
    private var resetActions: some View { Section { Button("Reset Demo Household", role: .destructive) { showingReset = true }; Button("Return to Live Server Login") { dismiss() } } }
}

private struct PersonaRow: View {
    let person: DemoPersona
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(person.initials).font(.headline).frame(width: 38, height: 38).background(Theme.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading) { Text(person.rawValue).foregroundStyle(.primary); Text(person.role).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.healthy) }
            }
        }
    }
}

struct MemberAccessView:View{
    var body: some View {
        List {
            ForEach(DemoPersona.allCases) { person in
                Section(person.rawValue) {
                    LabeledContent("Role", value: person.role)
                    if person.isChild {
                        Label("Can view delegated categories", systemImage: "checkmark.circle.fill")
                        Label("Can add own transactions", systemImage: "checkmark.circle.fill")
                        Label("Can request money", systemImage: "checkmark.circle.fill")
                        Label("Cannot view household accounts", systemImage: "lock.fill")
                        Label("Cannot view income, debt, or net worth", systemImage: "lock.fill")
                    } else {
                        Label("Full budget authority", systemImage: "checkmark.shield.fill")
                        Label("Accounts, plan, reports, approvals", systemImage: "checkmark.circle.fill")
                    }
                }
            }
        }.navigationTitle("Members & Access")
    }
}
struct RequestsView:View{
    @EnvironmentObject private var store:DemoStore
    var requests:[DemoRequest]{store.isRestricted ? store.requests.filter{$0.member==store.persona}:store.requests}
    var body:some View{List{ForEach(requests){request in NavigationLink{RequestApprovalView(request:request)}label:{VStack(alignment:.leading,spacing:5){HStack{Text(request.reason).fontWeight(.semibold);Spacer();MoneyText(amount:request.approvedAmount ?? request.amount)};HStack{Text(request.member.rawValue);Spacer();StatusLabel(title:request.status,systemImage:request.status=="Pending" ? "clock.fill" : request.status.contains("Approved")||request.status.contains("approved") ? "checkmark.circle.fill":"xmark.circle.fill",color:request.status=="Pending" ? Theme.attention : request.status.contains("Approved")||request.status.contains("approved") ? Theme.healthy:.secondary)}}.padding(.vertical,4)}}}.navigationTitle(store.isRestricted ? "My Requests":"Requests & Approvals")}
}

struct RequestApprovalView:View{
    @EnvironmentObject private var store:DemoStore;@Environment(\.dismiss)private var dismiss;let request:DemoRequest;@State private var amount="20.00";@State private var source="General Buffer";var minor:Int64{Int64((Double(amount) ?? 0)*100)}
    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("\(request.member.rawValue)’s request").font(.headline)
                    MoneyText(amount: request.amount, style: .system(size: 36, weight: .bold, design: .rounded))
                    Text(request.reason).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding()
            }
            Section("Destination") {
                LabeledContent("Category", value: store.categories.first(where: { $0.id == request.categoryID })?.name ?? "Allowance")
                LabeledContent("Requested", value: store.money(request.amount))
                LabeledContent("Status", value: request.status)
            }
            if !store.isRestricted && request.status == "Pending" {
                Section("Approval preview") {
                    Picker("Funding source", selection: $source) { Text("Household Fun · $120").tag("Household Fun"); Text("General Buffer · $350").tag("General Buffer") }
                    TextField("Approved amount", text: $amount).keyboardType(.decimalPad)
                    LabeledContent("Source after", value: (35000-minor).demoCurrency)
                    LabeledContent("Destination after", value: (4200+minor).demoCurrency)
                    Text("Nothing moves until you confirm.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Approve \(store.money(minor))", systemImage: "checkmark.circle.fill") { store.approve(request.id,amount:minor); dismiss() }.disabled(minor <= 0 || minor > request.amount)
                    Button("Decline", role: .destructive) { dismiss() }
                }
            }
        }.navigationTitle("Request").navigationBarTitleDisplayMode(.inline)
    }
}

struct AllowancesView:View{
    @EnvironmentObject private var store:DemoStore
    var plans:[DemoAllowance]{store.isRestricted ? store.allowances.filter{$0.member==store.persona}:store.allowances}
    var body:some View{List{ForEach(plans){plan in Section(plan.member.rawValue){LabeledContent(plan.frequency){MoneyText(amount:plan.amount)};LabeledContent("Next",value:plan.nextDate);if !store.isRestricted{LabeledContent("Funding source",value:plan.source)};ForEach(plan.splits,id:\.0){split in LabeledContent(split.0){MoneyText(amount:split.1)}};LabeledContent("Rollover",value:plan.rollover ? "Yes":"Use it or lose it");if !store.isRestricted{Button("Issue Due Allowance",systemImage:"arrow.right.circle.fill"){store.issueAllowance(plan.id)};Button(plan.isPaused ? "Resume":"Pause",systemImage:plan.isPaused ? "play.fill":"pause.fill"){if let index=store.allowances.firstIndex(where:{$0.id==plan.id}){store.allowances[index].isPaused.toggle()}}}}}}.navigationTitle("Allowances")}
}
