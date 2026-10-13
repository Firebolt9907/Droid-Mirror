import Foundation

@main
struct NotificationDeliveryTests {
    static func main() {
        if !NotificationRuntime.background {
            precondition(NotificationRuntime.preferences === UserDefaults.standard,
                         "Host must not force-unwrap its own preferences suite")
        }
        var policy = NotificationDeliveryPolicy()
        var focus = NotificationFocusPolicy()
        precondition(focus.requestOnce())
        for _ in 0..<100 { precondition(!focus.requestOnce(), "Reconnect retries must never steal focus") }
        focus = NotificationFocusPolicy(); precondition(focus.requestOnce())
        precondition(policy.shouldDeliver(), "Background receiver must deliver without mirroring")
        policy.session(active: true)
        precondition(!policy.shouldDeliver(), "Active mirroring must suppress notifications")
        policy.session(active: false)
        precondition(policy.shouldDeliver(), "Closing mirroring must resume delivery")
        policy.reconcile(hostIsRunning: true, hasSessionState: false)
        precondition(!policy.shouldDeliver(), "Launch must suppress before first heartbeat")
        policy.reconcile(hostIsRunning: false, hasSessionState: false)
        precondition(policy.shouldDeliver(), "Exit before heartbeat must not leave suppression stuck")
        for _ in 0..<20 {
            policy.session(active: true); precondition(!policy.shouldDeliver())
            policy.session(active: false); precondition(policy.shouldDeliver())
        }
        print("Notification delivery policy tests passed")
    }
}
