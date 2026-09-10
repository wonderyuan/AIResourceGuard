import Foundation
import UserNotifications

/// UNUserNotificationCenter wrapper. Authorization (alert + sound) is
/// requested once at app start; notifications respect the user's system
/// settings and the RiskEngine's own cooldown logic.
///
/// Clicking a notification that carries `userInfo["open"] == "incident"`
/// invokes `onOpenIncident` (wired by MonitorCenter to the incident window).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onOpenIncident: (() -> Void)?

    private var didSetup = false

    func requestIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, openIncident: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if openIncident {
                content.userInfo = ["open": "incident"]
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["open"] as? String == "incident" {
            DispatchQueue.main.async { [weak self] in
                self?.onOpenIncident?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners even while the (accessory) app happens to be active.
        completionHandler([.banner, .sound])
    }
}
