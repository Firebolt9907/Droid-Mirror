import Foundation

/// Classify actual failure signatures, rather than incidental mentions in setup advice.
struct ConnectionFailure {
    let title: String
    let message: String
    let showsLog: Bool

    static func recognize(_ diagnostic: String) -> ConnectionFailure {
        let text = diagnostic.lowercased()
        func has(_ signatures: String...) -> Bool { signatures.contains { text.contains($0) } }
        func known(_ title: String, _ message: String) -> ConnectionFailure {
            ConnectionFailure(title: title, message: message, showsLog: false)
        }
        if has("automatic unlock paused after an incomplete startup") {
            return known("Automatic unlock paused", "On your Android phone, open DroidMirror → Optional features and recovery → Automatic unlock / saved PIN. Check and save your PIN again, or remove it to unlock manually. Then lock the phone and reconnect.")
        }
        if has("event pin_failed", "automatic unlock failed") {
            return known("Automatic unlock failed", "Mirroring remains available for manual unlock. Wait 15 seconds before reconnecting to try automatic entry again. If it keeps failing, check the saved screen-lock PIN and any lockout message on your phone.")
        }
        if has("event phone_on", "event phone_local_use") {
            return known("Phone in use", "Your phone’s power or screen-lock action ended remote streaming. Lock your phone, then connect again when you’re ready.")
        }
        if has("event session_ended") {
            return known("Remote session ended", "The mirror session ended on your phone. Connect again when you’re ready.")
        }
        if has("event phone_in_use", "phone is in use") {
            return known("Phone in use", "Lock your Android phone, then connect again.")
        }
        if has("shizuku is not authorized", "shizuku permission denied", "authorize shizuku first", "grant shizuku permission") {
            return known("Authorize Shizuku", "Allow DroidMirror in Shizuku’s Authorized applications, then connect again.")
        }
        if has("shizuku unavailable", "shizuku is not running", "shizuku not running", "start shizuku", "shizuku guard timed out", "shizuku display guard disconnected") {
            return known("Start Shizuku", "Start Shizuku on your Android phone and allow DroidMirror access, then connect again.")
        }
        if has("device unauthorized", "device is unauthorized", "authorize usb debugging") {
            return known("Allow USB debugging", "Unlock your Android phone and accept the USB debugging prompt, then connect again.")
        }
        if has("device offline", "device is offline", "no devices/emulators found", "device not found") {
            return known("Phone disconnected", "Reconnect your phone. For Wi-Fi, check wireless debugging and that both devices are on the same network.")
        }
        if has("ble input unavailable", "bluetooth is powered off", "bluetooth access denied") {
            return known("Enable Bluetooth", "Turn on Bluetooth on both devices and allow DroidMirror Bluetooth access in macOS System Settings → Privacy & Security.")
        }
        if has("pair the phone in macos bluetooth settings", "no ble pairing key", "pairing key missing", "pair ble once in droidmirror settings") {
            return known("Pair your phone", "Pair your phone in macOS Bluetooth settings, then enter the Android companion’s pairing code in DroidMirror settings.")
        }
        if has("could not open classic l2cap", "classic l2cap connection failed", "bluetooth classic l2cap connection failed", "background bridge disabled", "bridge is disabled", "enable the background bridge") {
            return known("Enable bridge on Android phone", "Open DroidMirror on your Android phone and enable Mac connections (the background bridge). Check that Shizuku is running, then connect again.")
        }
        if has("timed out", "connection timeout", "operation timeout", "etimedout", "operation stalled", "input stalled", "response stalled", "video bridge stalled") {
            return known("Timed out", "Keep your phone nearby and try again. For Bluetooth, enable Mac connections in the Android companion and check that Shizuku is running.")
        }
        if has("event capture_failed", "hevc capture unavailable", "could not create video encoder", "no supported video encoder") {
            return known("Could not start screen capture", "Check that Shizuku is running and DroidMirror is authorized. Enable Mac connections on your phone. If this continues, check the phone’s HEVC encoder support.")
        }
        if has("ble input disconnected", "bluetooth stream closed") {
            return known("Bluetooth disconnected", "Keep your phone nearby with Bluetooth and Mac connections enabled, then connect again.")
        }
        if has("ble clock synchronization failed", "bluetooth input helper requires an updated app", "invalid bluetooth stream or video backlog exceeded") {
            return known("Update DroidMirror", "Update both the Android companion and Mac app, then connect again.")
        }
        if has("accessibility permission") {
            return known("Allow Accessibility access", "Enable DroidMirror in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        if has("paste the full ble pairing code") {
            return known("Check the pairing code", diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if has("helper missing", "renderer is missing", "scrcpy was not found", "select a paired bluetooth phone", "wi-fi aware direct mirroring is not available yet", "macos blocked adb") {
            return known("Setup required", diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ConnectionFailure(title: "Connection failed", message: "An unexpected error occurred. The full log is open in a separate window.", showsLog: true)
    }
}
