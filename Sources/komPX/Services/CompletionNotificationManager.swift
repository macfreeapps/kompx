import Foundation
import UserNotifications

final class CompletionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotificationManager()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyFinished(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "komPX finished"
        content.body = summary.isEmpty ? "All queued media has finished processing." : summary
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "komPX.compression-finished." + UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
