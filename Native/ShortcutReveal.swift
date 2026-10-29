import Foundation

/// Local presentation state only; it never authorizes a phone command.
enum ShortcutReveal {
    static let key = "DroidMirror.shortcutReveal"
    static let changed = Notification.Name("app.droidmirror.shortcutReveal")
    static func prepare(_ token: String) {
        let defaults = NotificationRuntime.preferences
        defaults.set(["token": token, "expires": Date().addingTimeInterval(60).timeIntervalSinceReferenceDate,
                      "ready": false] as [String: Any], forKey: key)
        defaults.synchronize()
        NotificationRuntime.post(changed.rawValue)
    }
    static func finish(_ token: String, _ displayedAtUs: Int64?) {
        let defaults = NotificationRuntime.preferences
        guard var state = defaults.dictionary(forKey: key), state["token"] as? String == token else { return }
        state["ready"] = true
        if let displayedAtUs, displayedAtUs > 0 { state["displayedAtUs"] = displayedAtUs }
        defaults.set(state, forKey: key); defaults.synchronize()
        NotificationRuntime.post(changed.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard defaults.dictionary(forKey: key)?["token"] as? String == token else { return }
            defaults.removeObject(forKey: key); defaults.synchronize()
        }
    }
}
