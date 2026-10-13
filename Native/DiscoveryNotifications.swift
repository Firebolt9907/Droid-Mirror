import Foundation
import UserNotifications

// One warning per launch, not one warning for every BLE/ADB retry.
struct DiscoveryNotificationPolicy {
    private(set) var finished = false
    private(set) var warned = false

    mutating func connected() { finished = true }
    mutating func stopped() { finished = true }
    mutating func discoveryExpired() -> Bool {
        guard !finished, !warned else { return false }
        warned = true
        return true
    }
}

final class DiscoveryNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onResponse: ((UNNotificationResponse) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var policy = DiscoveryNotificationPolicy()
    private var timeout: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private static let notificationID = "DroidMirror.phoneNotFound"

    override convenience init() { self.init(warningsEnabled: true) }

    init(warningsEnabled: Bool) {
        super.init()
        center.delegate = self
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("app.droidmirror.mirrorStarted"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.connected() }
        // Do not leave a stale failure notification after a new launch.
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            NSLog("DroidMirror notification authorization status: %ld", settings.authorizationStatus.rawValue)
            if settings.authorizationStatus == .notDetermined {
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { NSLog("DroidMirror notifications: %@", error.localizedDescription) }
                    if granted && warningsEnabled { DispatchQueue.main.async { self.beginDiscoveryGracePeriod() } }
                }
            } else if settings.authorizationStatus != .denied && warningsEnabled {
                DispatchQueue.main.async { self.beginDiscoveryGracePeriod() }
            }
        }
    }

    private func beginDiscoveryGracePeriod() {
        guard !policy.finished else { return }
        let work = DispatchWorkItem { [weak self] in self?.discoveryExpired() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func discoveryExpired() {
        guard policy.discoveryExpired() else { return }
        let content = UNMutableNotificationContent()
        content.title = "DroidMirror couldn’t find a phone"
        content.body = "Check your USB connection, or enable Wireless Debugging and BLE ADB Bridge with Bluetooth and network access. Make sure this Mac is authorized. DroidMirror will keep trying."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error { NSLog("DroidMirror notification failed: %@", error.localizedDescription) }
            DispatchQueue.main.async {
                guard let self, self.policy.finished else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
                self.center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            }
        }
    }

    private func connected() {
        policy.connected()
        timeout?.cancel()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    func stop() {
        policy.stopped()
        timeout?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.userInfo["quiet"] as? Bool == true ? [.list] : [.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onResponse?(response); completionHandler() }
    }
}
