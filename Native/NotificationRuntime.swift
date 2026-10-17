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
    static func isHost(pid: Int32) -> Bool {
        guard pid > 0, let process = NSRunningApplication(processIdentifier: pid), !process.isTerminated else { return false }
        return process.bundleIdentifier == "app.droidmirror.mac" && process.bundleURL == host?.bundleURL
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
    func shouldDeliver(event: [String: Any]) -> Bool {
        // Older companions omit these fields; keep their ordinary notifications
        // working while newer companions filter persistent items at the source.
        let package = event["package"] as? String ?? ""
        return package != "app.droidmirror.bluetooth" &&
            event["ongoing"] as? Bool != true && event["persistent"] as? Bool != true
    }
}

// The launcher execs the Swift host. LaunchServices may retain a stale -1 PID
// even while the host is alive; its session heartbeat carries the actual PID.
struct MirrorWindowCommandTarget {
    private var pid: Int32?
    private var updatedAt = Date.distantPast

    mutating func session(pid: Int, active: Bool, now: Date = Date()) {
        guard let validPID = Int32(exactly: pid), validPID > 0 else { return }
        if active {
            self.pid = validPID
            updatedAt = now
        } else if self.pid == validPID {
            self.pid = nil
        }
    }

    func target(now: Date = Date()) -> Int32? {
        guard now.timeIntervalSince(updatedAt) <= 3 else { return nil }
        return pid
    }
}
