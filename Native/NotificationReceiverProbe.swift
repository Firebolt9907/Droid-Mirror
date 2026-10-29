import AppKit

@main
struct NotificationReceiverProbe {
    static func main() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.droidmirror.receiverStatus"), object: nil, queue: .main) { event in
                print("Receiver status: \(event.userInfo?["status"] ?? "unknown")")
                print("App library: \(event.userInfo?["appLibrary"] ?? "unavailable")")
                print("Delivery counters: \(event.userInfo?["notifications"] ?? "unknown")")
            }
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        DistributedNotificationCenter.default().removeObserver(observer)
        let receivers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.droidmirror.notifications")
        print("Background receivers: \(receivers.count)")
        print("Mirroring hosts: \(NSRunningApplication.runningApplications(withBundleIdentifier: "app.droidmirror.mac").count)")
        precondition(receivers.count == 1, "Exactly one background receiver must survive")
    }
}
