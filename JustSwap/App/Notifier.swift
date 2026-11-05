import Foundation
import UserNotifications

/// Posts the autoswitch notifications (switch, quarantine, all exhausted,
/// config warning) under the app's own identity.
@MainActor
final class Notifier {
    private var authorized = false

    func requestAuthorization() {
        Task {
            authorized = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
