import Foundation
import Observation
import UserNotifications

/// Local notifications for things that need the owner. These only fire while
/// iOS still lets the app run: there is no push server behind this app.
@MainActor
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// `info` comes back to `NotificationRouter` when the owner taps it.
    /// `inForeground`: show it even while the app is open.
    static func post(title: String, body: String, id: String = UUID().uuidString,
                     info: [String: String] = [:], inForeground: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        var userInfo: [String: String] = info
        if inForeground { userInfo["foreground"] = "1" }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Takes back a notification whose reason has passed, e.g. a prompt answered elsewhere.
    static func withdraw(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Where a tapped notification leads: a decision, a bot's permission card,
/// its Chat or its Work pane, on the computer it came from.
@MainActor
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Set when the owner taps a notification; the root view opens it.
    var target: NotificationTarget?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Most notifications are posted only in the background; a prompt for a
        // bot that is not on screen also shows while the app is open.
        notification.request.content.userInfo["foreground"] == nil ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let tapped = NotificationTarget(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { target = tapped }
    }
}
