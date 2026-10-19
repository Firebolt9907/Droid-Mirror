import Foundation

@main
struct NotificationDeliveryTests {
    static func main() {
        if !NotificationRuntime.background {
            precondition(NotificationRuntime.preferences === UserDefaults.standard,
                         "Host must not force-unwrap its own preferences suite")
        }
        let policy = NotificationDeliveryPolicy()
        var focus = NotificationFocusPolicy()
        precondition(focus.requestOnce())
        for _ in 0..<100 { precondition(!focus.requestOnce(), "Reconnect retries must never steal focus") }
        focus = NotificationFocusPolicy(); precondition(focus.requestOnce())
        let message: [String: Any] = ["type": "notification", "id": "message", "package": "com.example.chat"]
        precondition(policy.shouldDeliver(event: message), "Live messages must deliver independently of mirror state")
        precondition(policy.shouldDeliver(event: ["id": "legacy"]), "Older companions remain compatible")
        for field in ["ongoing", "persistent"] {
            var event = message
            event[field] = true
            precondition(!policy.shouldDeliver(event: event), "Persistent items must be filtered")
            event[field] = false
            precondition(policy.shouldDeliver(event: event))
        }
        precondition(!policy.shouldDeliver(event: ["package": "app.droidmirror.bluetooth"]),
                     "The companion's session history must not loop back to the Mac")
        for event: [String: Any] in [
            ["package": "android", "category": "sys"],
            ["package": "android", "channel": "PHYSICAL_KEYBOARD"],
            ["package": "com.android.systemui", "channel": "virtual_keyboard"],
            ["category": "service"], ["category": "transport"], ["progress": true]
        ] { precondition(!policy.shouldDeliver(event: event)) }
        for category in ["msg", "call", "alarm", "err"] {
            precondition(policy.shouldDeliver(event: ["package": "android", "category": category]))
        }
        precondition(policy.shouldDeliver(event: ["package": "downloads", "progress": false]))
        print("Notification delivery policy tests passed")
    }
}
