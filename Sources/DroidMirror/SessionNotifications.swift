import AppKit
@preconcurrency import UserNotifications

@MainActor
final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifications()
    private let center = UNUserNotificationCenter.current()
    private var sessionID: String?
    private override init() { super.init(); center.delegate = self }
    func requestPermission() async { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    func began() { if sessionID == nil { sessionID = UUID().uuidString } }
    func ended() async {
        guard let id = sessionID else { return }
        sessionID = nil // Closing, quit and disconnect callbacks share one notification.
        let content = UNMutableNotificationContent()
        content.title = "Phone was used remotely"
        content.body = "Your DroidMirror mirroring session ended."
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "DroidMirror.remote-use.\(id)", content: content, trigger: nil))
    }
    func localUse(restored: Bool) {
        let alert = NSAlert()
        alert.messageText = "phone was used"
        alert.informativeText = restored
            ? "phone turned on\n\nYour phone was locked and its display restored. Remote streaming stopped."
            : "The phone’s power or screen-lock action ended remote streaming. Locking or display restoration could not be confirmed."
        alert.addButton(withTitle: "OK")
        SettingsWindowController.shared.show(model: MirrorModel.shared)
        if let window = SettingsWindowController.shared.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
