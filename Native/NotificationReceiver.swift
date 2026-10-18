import AppKit

final class LinkShareDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { stopDroidMirrorBLE() }
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { shareDroidMirrorLink($0) }
    }
}

@main
struct NotificationReceiver {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // LaunchServices normally coalesces app launches; also guard direct execution.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "app.droidmirror.notifications")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return }
        let delegate = LinkShareDelegate()
        app.delegate = delegate
        startDroidMirrorBLE()
        withExtendedLifetime(delegate) { app.run() }
    }
}
