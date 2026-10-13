import AppKit

@main
struct NotificationReceiver {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // LaunchServices normally coalesces app launches; also guard direct execution.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "app.droidmirror.notifications")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return }
        startDroidMirrorBLE()
        app.run()
    }
}
