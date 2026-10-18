import Foundation

@main
struct NotificationAppPreferencesTests {
    static func main() {
        let domain = "app.droidmirror.notification-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotificationAppPreferences(defaults: defaults)
        let chat: [String: Any] = ["id": "chat", "package": "com.example.chat", "app": "Chat"]
        let other: [String: Any] = ["id": "other", "package": "com.example.other", "app": "Chat"]
        precondition(preferences.allows(chat))
        precondition(preferences.record(chat))
        precondition(!preferences.record(chat))
        precondition(preferences.record(other))
        precondition(preferences.apps.count == 2, "Apps with the same name remain separate")
        preferences.setAllowed(false, package: "com.example.chat")
        precondition(!preferences.allows(chat))
        precondition(preferences.allows(other))
        precondition(preferences.allows(["app": "Chat"]), "Legacy events without package remain compatible")
        let restarted = NotificationAppPreferences(defaults: UserDefaults(suiteName: domain)!)
        precondition(!restarted.allows(chat), "Exclusions survive receiver restart")
        precondition(!restarted.record(chat), "Excluded apps remain in the catalog")
        precondition(restarted.record(["package": "com.example.chat", "app": "Renamed Chat"]))
        precondition(!restarted.allows(chat), "Renames cannot bypass exclusion")
        precondition(restarted.record(["package": "com.example.unnamed"]))
        precondition(restarted.apps["com.example.unnamed"] == "com.example.unnamed")
        precondition(!restarted.record(["app": "Missing package"]))
        restarted.setAllowed(false, package: "com.example.other")
        restarted.setAllowed(true, package: "com.example.chat")
        precondition(restarted.allows(chat))
        precondition(!restarted.allows(other), "Re-enabling one app preserves other choices")
        print("Notification app preference tests passed")
    }
}
