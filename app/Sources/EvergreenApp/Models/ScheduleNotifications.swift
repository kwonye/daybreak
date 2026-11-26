import AppKit
import EvergreenKit
import UserNotifications

@MainActor
enum ScheduleNotifications {
    static let category = "evergreen.schedule.missed"
    static let runAction = "evergreen.schedule.run"

    static func configure() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let run = UNNotificationAction(identifier: runAction, title: "Run Updates Now", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [run], intentIdentifiers: [])
        ])
    }

    static func requestPermission(openSettingsIfDenied: Bool = false) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge])
        } else if openSettingsIfDenied, settings.authorizationStatus == .denied,
                  let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func post(_ reminder: ScheduleReminder) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Scheduled update missed"
        let count = reminder.updateCount
        content.body = count == 1 ? "1 update is ready. Click to run it now." : "\(count) updates are ready. Click to run them now."
        content.categoryIdentifier = category
        content.userInfo = ["scheduledAt": reminder.scheduledAt.timeIntervalSince1970]
        let id = "\(category).\(Int(reminder.scheduledAt.timeIntervalSince1970))"
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func clear(_ reminder: ScheduleReminder) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let id = "\(category).\(Int(reminder.scheduledAt.timeIntervalSince1970))"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
