import AppKit

// The receiver is a separate, UI-less app. It owns the only BLE connection;
// the mirroring host retains settings and publishes session state.
enum NotificationRuntime {
    static var background: Bool { Bundle.main.bundleIdentifier == "app.droidmirror.notifications" }
    // Foundation rejects an app's own identifier as a suite name. The host
    // must use .standard; only the separate helper opens the host's domain.
    static let preferences: UserDefaults = {
        if background { return UserDefaults(suiteName: "app.droidmirror.mac") ?? .standard }
        return .standard
    }()
    static var host: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "app.droidmirror.mac").first
    }
    static func post(_ name: String, info: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil,
            userInfo: info, deliverImmediately: true)
    }
    static func requestMirror(activate: Bool = true) {
        if let host {
            post("app.droidmirror.requestMirror")
            if activate { host.activate(options: [.activateAllWindows]) }
        } else {
            // Helpers/DroidMirror Notifications.app lives inside the parent app.
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activate
            NSWorkspace.shared.openApplication(at: parent, configuration: configuration) { _, error in
                if let error { NSLog("DroidMirror could not launch mirroring: %@", error.localizedDescription) }
            }
        }
    }
}

struct NotificationFocusPolicy {
    private var requested = false
    mutating func requestOnce() -> Bool {
        guard !requested else { return false }
        requested = true
        return true
    }
}

struct NotificationDeliveryPolicy {
    private(set) var active = false
    mutating func session(active: Bool) { self.active = active }
    mutating func reconcile(hostIsRunning: Bool, hasSessionState: Bool) {
        if !hostIsRunning { active = false }
        else if !hasSessionState { active = true }
    }
    func shouldDeliver() -> Bool { !active }
}
