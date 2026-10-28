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
        let activities = ActivityAppPreferences(defaults: defaults)
        let timer: [String: Any] = ["package": "com.example.chat", "app": "Chat", "channel": "timer", "channelName": "Timers"]
        let navigation: [String: Any] = ["package": "com.example.chat", "app": "Chat", "channel": "navigation"]
        precondition(activities.record(timer))
        precondition(activities.record(navigation))
        let source = ActivityAppPreferences.source(timer)!
        activities.setAllowed(false, source: source)
        precondition(!activities.allows(timer))
        precondition(activities.allows(navigation), "Activity types from one app have independent controls")
        precondition(restarted.allows(chat), "Activity controls do not change regular notification controls")
        restarted.setAllowed(false, package: "com.example.chat")
        precondition(activities.allows(navigation), "Regular notification controls do not disable live activities")
        let activityRestart = ActivityAppPreferences(defaults: UserDefaults(suiteName: domain)!)
        precondition(!activityRestart.allows(timer), "Activity exclusions survive receiver restart")
        precondition(activityRestart.sources[source]?["name"] == "Timers")
        precondition(!activityRestart.record(timer), "Catalog updates do not reset exclusions")
        activityRestart.setAllowed(true, source: source)
        precondition(activityRestart.allows(timer))
        print("Notification and activity preference tests passed")
    }
}
