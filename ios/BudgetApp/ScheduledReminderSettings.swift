import BudgetAPI
import Foundation
import UserNotifications

@MainActor
final class ScheduledReminderSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published var errorMessage: String?
    private let budgetID: String
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter

    init(budgetID: String, defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.budgetID = budgetID
        self.defaults = defaults
        self.center = center
        isEnabled = defaults.bool(forKey: Self.key(budgetID))
    }

    func setEnabled(_ enabled: Bool, schedules: [APIScheduledTransaction]) async {
        if enabled {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    errorMessage = "Notifications are disabled for ClearPocket. You can enable them in iPhone Settings."
                    return
                }
                isEnabled = true
                defaults.set(true, forKey: Self.key(budgetID))
                await synchronize(schedules)
            } catch { errorMessage = error.localizedDescription }
        } else {
            isEnabled = false
            defaults.set(false, forKey: Self.key(budgetID))
            await removeOwnedRequests()
        }
    }

    func synchronize(_ schedules: [APIScheduledTransaction], now: Date = Date()) async {
        guard isEnabled else { return }
        await removeOwnedRequests()
        let upcoming = schedules.compactMap { schedule -> (APIScheduledTransaction, Date)? in
            guard schedule.isActive, let date = Self.fireDate(nextDate: schedule.nextDate, now: now) else { return nil }
            return (schedule, date)
        }.sorted { $0.1 < $1.1 }.prefix(50)
        for (schedule, fireDate) in upcoming {
            let content = UNMutableNotificationContent()
            content.title = "ClearPocket reminder"
            content.body = "A scheduled budget item is due today."
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let request = UNNotificationRequest(
                identifier: requestPrefix + schedule.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            try? await center.add(request)
        }
    }

    nonisolated static func fireDate(nextDate: String, now: Date, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let due = formatter.date(from: nextDate),
              let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due),
              start > now,
              start <= calendar.date(byAdding: .day, value: 60, to: now) ?? now else { return nil }
        return start
    }

    private func removeOwnedRequests() async {
        let identifiers = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private var requestPrefix: String { "clearpocket.schedule.\(budgetID)." }
    private static func key(_ budgetID: String) -> String { "clearpocket.scheduled-reminders.\(budgetID)" }
}
