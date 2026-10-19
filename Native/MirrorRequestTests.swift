import AppKit

@main
struct MirrorRequestTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        var attempts = 0
        let handler = MirrorRequestHandler { attempts += 1 }
        let center = DistributedNotificationCenter.default()
        func send(to destination: String?) {
            center.postNotificationName(Notification.Name("app.droidmirror.requestMirror"),
                                        object: destination, userInfo: nil, deliverImmediately: true)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        withExtendedLifetime(handler) {
            send(to: String(ProcessInfo.processInfo.processIdentifier))
            precondition(attempts == 1, "Connect Again must reach the host")
            send(to: String(ProcessInfo.processInfo.processIdentifier))
            precondition(attempts == 2, "Subsequent reconnects must still work")
            send(to: "another-host")
            precondition(attempts == 2, "Requests for other hosts must be ignored")
            send(to: nil)
            precondition(attempts == 3, "Background notification requests must still work")
        }
        print("PASS: reconnect and background requests reach the host; other hosts are ignored")
    }
}
