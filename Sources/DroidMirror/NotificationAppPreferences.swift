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
