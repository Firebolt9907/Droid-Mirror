import AppKit

// Run outside the sandbox with DroidMirror open. Its launcher can leave the
// LaunchServices listing at PID -1, even though PID-based lookup works.
@main
struct NotificationHostProbe {
    static func main() {
        precondition(!NotificationRuntime.isHost(pid: -1))
        precondition(!NotificationRuntime.isHost(pid: 0))
        precondition(!NotificationRuntime.isHost(pid: ProcessInfo.processInfo.processIdentifier),
                     "An unrelated executable must not be accepted as the host")
        var heartbeats = 0
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.droidmirror.sessionState"), object: nil, queue: .main) { event in
                guard let value = event.userInfo?["pid"] as? Int, let pid = Int32(exactly: value) else { return }
                precondition(NotificationRuntime.isHost(pid: pid), "Real host heartbeat must survive stale LaunchServices PID")
                heartbeats += 1
            }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        DistributedNotificationCenter.default().removeObserver(observer)
        precondition(heartbeats > 0, "Open DroidMirror before running this live probe")
        print("Host identity probe passed: accepted \(heartbeats) real heartbeats; rejected invalid/unrelated PIDs")
    }
}
