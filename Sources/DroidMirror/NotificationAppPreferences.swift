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

/// Activity controls are independent of notification banners and scoped to a stable kind
/// of activity per Android app. Apps such as Google Maps rotate channel IDs (and sometimes
/// channel names) per trip or per guidance step, so grouping by raw channel produced a new
/// settings row for every navigation. A source is the app plus Android's notification
/// category when the app supplies one, otherwise its channel name (or ID) with volatile
/// numbers, hex tokens and UUIDs removed.
struct ActivityAppPreferences {
    static let catalogChanged = Notification.Name("app.droidmirror.activityAppsChanged")
    let defaults: UserDefaults
    private let catalogKey = "DroidMirror.activities.groups"
    private let legacyCatalogKey = "DroidMirror.activities.sources"
    private let excludedKey = "DroidMirror.activities.excludedSources"
    var sources: [String: [String: String]] { defaults.dictionary(forKey: catalogKey) as? [String: [String: String]] ?? [:] }
    var excluded: Set<String> { Set(defaults.stringArray(forKey: excludedKey) ?? []) }

    private static let categoryNames = [
        "navigation": "Navigation", "call": "Calls", "missed_call": "Missed calls", "alarm": "Alarms",
        "reminder": "Reminders", "event": "Events", "progress": "Progress", "service": "Background services",
        "stopwatch": "Stopwatch", "workout": "Workouts", "location_sharing": "Location sharing",
        "status": "Status", "sys": "System", "msg": "Messages", "email": "Email", "social": "Social",
        "recommendation": "Recommendations", "promo": "Promotions", "err": "Errors", "voicemail": "Voicemail",
    ]

    /// Strips per-instance tokens so "nav_channel_1731700000" and "nav_channel_1731790000" match.
    static func stableLabel(_ value: String) -> String {
        var text = value
        // UUIDs first (they contain separators), then separators, then hex tokens and counters.
        for pattern in ["[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                        "[_.:#/\\-]+", "\\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{8,}\\b", "[0-9]+", "\\s+"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The grouping key (without package) and a human-readable name for Settings and menus.
    static func kind(_ event: [String: Any]) -> (key: String, name: String) {
        let category = (event["category"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !category.isEmpty {
            let name = categoryNames[category] ?? stableLabel(category).capitalized
            return ("category:" + category, name.isEmpty ? category : name)
        }
        for field in ["channelName", "channel"] {
            let label = stableLabel(event[field] as? String ?? "")
            if !label.isEmpty { return ("name:" + label.lowercased(), label) }
        }
        return ("other", "Other activities")
    }

    static func source(_ event: [String: Any]) -> String? {
        guard let package = event["package"] as? String, !package.isEmpty else { return nil }
        return package + "\n" + kind(event).key
    }
    /// Pre-grouping builds keyed exclusions by the raw channel ID.
    static func legacySource(_ event: [String: Any]) -> String? {
        guard let package = event["package"] as? String, !package.isEmpty else { return nil }
        return package + "\n" + (event["channel"] as? String ?? "")
    }
    func allows(_ event: [String: Any]) -> Bool {
        guard let source = Self.source(event) else { return true }
        let values = excluded
        return !values.contains(source) && !(Self.legacySource(event).map { values.contains($0) } ?? false)
    }
    @discardableResult func record(_ event: [String: Any]) -> Bool {
        guard let source = Self.source(event), let package = event["package"] as? String else { return false }
        if defaults.object(forKey: legacyCatalogKey) != nil { defaults.removeObject(forKey: legacyCatalogKey) }
        // Carry an old per-channel exclusion over to its group, once.
        var values = excluded
        if let legacy = Self.legacySource(event), legacy != source, values.remove(legacy) != nil {
            values.insert(source)
            defaults.set(values.sorted(), forKey: excludedKey)
        }
        let app = (event["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = Self.kind(event)
        let row = ["app": app.isEmpty ? package : app, "package": package, "kind": kind.key, "name": kind.name]
        var catalog = sources
        guard catalog[source] != row else { defaults.synchronize(); return false }
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
