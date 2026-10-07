import SwiftUI
import WidgetKit

private struct ClearPocketEntry: TimelineEntry { let date: Date }

private struct ClearPocketProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClearPocketEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ClearPocketEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClearPocketEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date())], policy: .never))
    }
}

private struct ClearPocketWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ClearPocket", systemImage: "wallet.bifold.fill").font(.headline)
            Text("Your budget stays private. Choose where to pick up.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if family == .systemSmall {
                destination("Add transaction", "activity", "plus.circle.fill")
            } else {
                HStack { destination("Plan", "plan", "list.bullet.rectangle"); destination("Activity", "activity", "plus.circle.fill") }
                HStack { destination("Accounts", "accounts", "building.columns"); destination("Insights", "insights", "chart.pie.fill") }
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func destination(_ title: String, _ value: String, _ symbol: String) -> some View {
        Link(destination: URL(string: "clearpocket://open?destination=\(value)")!) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Open ClearPocket \(title)")
    }
}

private struct ClearPocketLauncherWidget: Widget {
    let kind = "ClearPocketLauncherWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClearPocketProvider()) { _ in ClearPocketWidgetView() }
            .configurationDisplayName("ClearPocket shortcuts")
            .description("Open common ClearPocket screens without displaying financial information.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main struct ClearPocketWidgetBundle: WidgetBundle {
    var body: some Widget { ClearPocketLauncherWidget() }
}
