import BudgetAPI
import Foundation
import UserNotifications

@MainActor
protocol ScheduledReminderNotificationClient: AnyObject {
    func authorize() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func remove(_ identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemScheduledReminderNotifications: ScheduledReminderNotificationClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter) { self.center = center }
    func authorize() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func remove(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

@MainActor
final class ScheduledReminderSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published var errorMessage: String?
    private let budgetID: String
    private let defaults: UserDefaults
    private let notifications: any ScheduledReminderNotificationClient
    private var preferenceRevision = UUID()
    private var synchronizationRevision = UUID()
    private var latestSchedules: [APIScheduledTransaction] = []
    private var latestNow = Date()
    private var worker: Task<Void, Never>?

    convenience init(budgetID: String, defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.init(budgetID: budgetID, defaults: defaults, notifications: SystemScheduledReminderNotifications(center: center))
    }

    init(budgetID: String, defaults: UserDefaults, notifications: any ScheduledReminderNotificationClient) {
        self.budgetID = budgetID
        self.defaults = defaults
        self.notifications = notifications
        isEnabled = defaults.bool(forKey: Self.key(budgetID))
    }

    func setEnabled(_ enabled: Bool, schedules: [APIScheduledTransaction]) async {
        let revision = UUID(); preferenceRevision = revision
        latestSchedules = schedules; latestNow = Date(); errorMessage = nil
        if enabled {
            do {
                let allowed = try await notifications.authorize()
                guard preferenceRevision == revision else { return }
                guard allowed else {
                    errorMessage = "Notifications are disabled for ClearPocket. You can enable them in iPhone Settings."
                    return
                }
                isEnabled = true
                defaults.set(true, forKey: Self.key(budgetID))
                await requestSynchronization()
            } catch { if preferenceRevision == revision { errorMessage = error.localizedDescription } }
        } else {
            isEnabled = false
            defaults.set(false, forKey: Self.key(budgetID))
            await requestSynchronization()
        }
    }

    func synchronize(_ schedules: [APIScheduledTransaction], now: Date = Date()) async {
        latestSchedules = schedules; latestNow = now
        guard isEnabled else { return }
        await requestSynchronization()
    }

    private func requestSynchronization() async {
        synchronizationRevision = UUID()
        if let worker { await worker.value; return }
        let task = Task { await rebuildUntilCurrent(); worker = nil }
        worker = task
        await task.value
    }

    private func rebuildUntilCurrent() async {
        while true {
            let revision = synchronizationRevision
            let schedules = latestSchedules, now = latestNow
            let identifiers = await notifications.pendingIdentifiers().filter { $0.hasPrefix(requestPrefix) }
            notifications.remove(identifiers)
            guard revision == synchronizationRevision else { continue }
            let upcoming = (isEnabled ? schedules : []).compactMap { schedule -> (APIScheduledTransaction, Date)? in
                guard schedule.budgetID == budgetID, schedule.isActive,
                      let date = Self.fireDate(nextDate: schedule.nextDate, now: now) else { return nil }
                return (schedule, date)
            }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }.prefix(50)
            var failure: String?
            for (schedule, fireDate) in upcoming {
                guard revision == synchronizationRevision, isEnabled else { break }
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
                do { try await notifications.add(request) }
                catch { if failure == nil { failure = error.localizedDescription } }
            }
            if revision == synchronizationRevision { errorMessage = failure; return }
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

    private var requestPrefix: String { "clearpocket.schedule.\(budgetID)." }
    private static func key(_ budgetID: String) -> String { "clearpocket.scheduled-reminders.\(budgetID)" }
}
