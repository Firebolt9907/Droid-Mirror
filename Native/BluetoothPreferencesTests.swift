import Foundation

@main
struct BluetoothPreferencesTests {
    static func main() throws {
        let old = Data(#"{"transport":"adb","autoStart":false,"maxFPS":30}"#.utf8)
        var preferences = try JSONDecoder().decode(MirrorPreferences.self, from: old)
        precondition(preferences.bluetoothDeviceID == nil)
        precondition(preferences.transport == .adb && !preferences.autoStart && preferences.maxFPS == 30)
        preferences.bluetoothDeviceID = "AA-BB-CC-DD-EE-FF"
        let restored = try JSONDecoder().decode(MirrorPreferences.self, from: JSONEncoder().encode(preferences))
        precondition(restored.bluetoothDeviceID == preferences.bluetoothDeviceID)
        precondition(restored.transport == .adb && !restored.autoStart && restored.maxFPS == 30)
        print("Bluetooth preferences: old settings migrate and selected phone survives encoding without changing ADB settings")
    }
}
