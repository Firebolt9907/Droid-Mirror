import Foundation

@main
struct AutomaticTransportPreferencesTests {
    static func main() throws {
        for previous in MirrorTransport.allCases {
            try withDefaults { defaults, suite in
                var saved = MirrorPreferences()
                saved.transport = previous
                saved.bluetoothDeviceID = "AA-BB-CC-DD-EE-FF"
                saved.autoStart = false
                saved.maxFPS = 90
                saved.maxSize = 1280
                saved.bitRateMbps = 20
                saved.codec = .h265
                saved.scrollMode = .direct
                MirrorPreferencesStore.save(saved, to: defaults)

                let migrated = MirrorPreferencesStore.load(from: defaults)
                precondition(migrated.transport == .bluetoothClassic)
                // All unrelated preferences, including the remembered phone,
                // survive byte-for-byte when only transport is reset.
                saved.transport = .bluetoothClassic
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let migratedData = try encoder.encode(migrated)
                let expectedData = try encoder.encode(saved)
                precondition(migratedData == expectedData)
                let persisted = try JSONDecoder().decode(MirrorPreferences.self,
                    from: defaults.data(forKey: MirrorPreferencesStore.preferencesKey)!)
                precondition(persisted.transport == .bluetoothClassic)

                // A new preferences reader represents another launch. A later
                // explicit choice must not be reset on every launch.
                for choice in MirrorTransport.allCases {
                    var chosen = migrated; chosen.transport = choice
                    MirrorPreferencesStore.save(chosen, to: defaults)
                    let reopened = UserDefaults(suiteName: suite)!
                    precondition(MirrorPreferencesStore.load(from: reopened).transport == choice)
                }
            }
        }
        withDefaults { defaults, _ in
            precondition(MirrorPreferencesStore.load(from: defaults).transport == .bluetoothClassic)
            precondition(defaults.data(forKey: MirrorPreferencesStore.preferencesKey) != nil)
        }
        withDefaults { defaults, _ in
            defaults.set(Data("invalid old preferences".utf8), forKey: MirrorPreferencesStore.preferencesKey)
            precondition(MirrorPreferencesStore.load(from: defaults).transport == .bluetoothClassic)
        }
        print("Automatic transport preferences: legacy selections reset once, defaults persisted, later choices and other settings preserved")
    }

    static func withDefaults(_ test: (UserDefaults, String) throws -> Void) rethrows {
        let suite = "app.droidmirror.tests.automatic-transport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults, suite)
    }
}
