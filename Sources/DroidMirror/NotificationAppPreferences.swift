import Foundation

// Shared by Settings and the background receiver. The receiver writes the app
// catalog; Settings writes exclusions, so neither replaces the other's changes.
struct NotificationAppPreferences {
    static let changed = Notification.Name("app.droidmirror.notificationConfiguration")
    static let catalogChanged = Notification.Name("app.droidmirror.notificationAppsChanged")
    let defaults: UserDefaults
    private let appsKey = "DroidMirror.notifications.apps"
    private let excludedKey = "DroidMirror.notifications.excludedPackages"

    var apps: [String: String] { defaults.dictionary(forKey: appsKey) as? [String: String] ?? [:] }
    var excluded: Set<String> { Set(defaults.stringArray(forKey: excludedKey) ?? []) }

    func allows(_ event: [String: Any]) -> Bool {
        guard let package = event["package"] as? String else { return true }
        return !excluded.contains(package)
    }

    @discardableResult
    func record(_ event: [String: Any]) -> Bool {
        guard let package = event["package"] as? String, !package.isEmpty else { return false }
        let label = (event["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.isEmpty ? package : label
        var catalog = apps
        guard catalog[package] != name else { return false }
        catalog[package] = name
        defaults.set(catalog, forKey: appsKey)
        defaults.synchronize()
        return true
    }

    func setAllowed(_ allowed: Bool, package: String) {
        var packages = excluded
        if allowed { packages.remove(package) } else { packages.insert(package) }
        defaults.set(packages.sorted(), forKey: excludedKey)
        defaults.synchronize()
    }
}

/// Activity controls are independent of notification banners and scoped to Android channels.
struct ActivityAppPreferences {
    static let catalogChanged = Notification.Name("app.droidmirror.activityAppsChanged")
    let defaults: UserDefaults
    private let catalogKey = "DroidMirror.activities.sources"
    private let excludedKey = "DroidMirror.activities.excludedSources"
    var sources: [String: [String: String]] { defaults.dictionary(forKey: catalogKey) as? [String: [String: String]] ?? [:] }
    var excluded: Set<String> { Set(defaults.stringArray(forKey: excludedKey) ?? []) }

    static func source(_ event: [String: Any]) -> String? {
        guard let package = event["package"] as? String, !package.isEmpty else { return nil }
        return package + "\n" + (event["channel"] as? String ?? "")
    }
    func allows(_ event: [String: Any]) -> Bool {
        guard let source = Self.source(event) else { return true }
        return !excluded.contains(source)
    }
    @discardableResult func record(_ event: [String: Any]) -> Bool {
        guard let source = Self.source(event), let package = event["package"] as? String else { return false }
        let app = (event["app"] as? String ?? package)
        let channel = event["channel"] as? String ?? ""
        let supplied = (event["channelName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = supplied.isEmpty ? channel : supplied
        let row = ["app": app, "package": package, "channel": channel, "name": name]
        var catalog = sources
        guard catalog[source] != row else { return false }
        catalog[source] = row
        defaults.set(catalog, forKey: catalogKey)
        defaults.synchronize()
        return true
    }
    func setAllowed(_ allowed: Bool, source: String) {
        var values = excluded
        if allowed { values.remove(source) } else { values.insert(source) }
        defaults.set(values.sorted(), forKey: excludedKey)
        defaults.synchronize()
    }
}
