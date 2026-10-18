import AppKit
@preconcurrency import UserNotifications

@MainActor
final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifications()
    private let center = UNUserNotificationCenter.current()
    private override init() { super.init(); center.delegate = self }
    func requestPermission() async {
        // Clean up session-history banners from previous releases, leaving
        // other DroidMirror alerts and forwarded phone notifications intact.
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }
            .filter { $0.hasPrefix("DroidMirror.remote-use.") })
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
            .filter { $0.hasPrefix("DroidMirror.remote-use.") })
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    func localUse(restored: Bool) {
        present(title: "Phone is in use", message: restored
            ? "Your phone was used. Its display was restored and remote streaming stopped."
            : "The phone’s power or screen-lock action ended remote streaming. Locking or display restoration could not be confirmed.")
    }

    func present(title: String = "DroidMirror", message: String) {
        PhoneWindowController.shared.present(title: title, message: message, model: MirrorModel.shared)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
