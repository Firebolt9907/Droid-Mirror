import Foundation

enum MirrorPreferencesStore {
    static let preferencesKey = "DroidMirror.preferences.v1"
    private static let automaticTransportMigrationKey = "DroidMirror.automaticTransportDefault.v1"

    static func load(from defaults: UserDefaults = .standard) -> MirrorPreferences {
        var preferences = defaults.data(forKey: preferencesKey)
            .flatMap { try? JSONDecoder().decode(MirrorPreferences.self, from: $0) }
            ?? MirrorPreferences()

        // Apply once when upgrading from builds without Bluetooth-to-Wi-Fi
        // handoff. Persist immediately: initialization does not run didSet.
        if !defaults.bool(forKey: automaticTransportMigrationKey) {
            preferences.transport = .bluetoothClassic
            if save(preferences, to: defaults) {
                defaults.set(true, forKey: automaticTransportMigrationKey)
            }
        }
        return preferences
    }

    @discardableResult
    static func save(_ preferences: MirrorPreferences, to defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(preferences) else { return false }
        defaults.set(data, forKey: preferencesKey)
        return true
    }
}
