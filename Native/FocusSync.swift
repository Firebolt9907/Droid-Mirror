import Foundation
import Intents

/// Owned only by the background BLE receiver. Unknown Focus state never means off.
final class FocusSync {
    weak var controller: BLEController?
    private var timer: Timer?
    private var gate = FocusEchoGate()
    private var phoneGate = FocusPhoneGate()
    private var shortcutNames: [String] = []
    private var canSetPhone: Bool?
    private var token: String?
    private var requestedAuthorization = false
    private var process: Process?
    private var processDeadline: TimeInterval = 0
    private var wasSending = false
    private var wasReceiving = false
    private var prefs: UserDefaults { NotificationRuntime.preferences }
    private var lastError = ""
    var diagnostics: String {
        guard prefs.bool(forKey: "DroidMirror.focus.macToPhone") || prefs.bool(forKey: "DroidMirror.focus.phoneToMac") else { return "Focus sync off" }
        guard controller?.authenticated == true else { return "Focus sync waiting for Bluetooth" }
        guard controller?.supportsFocusSync == true else { return "Phone does not support Focus sync" }
        if !lastError.isEmpty { return "Focus sync: " + lastError }
        if prefs.bool(forKey: "DroidMirror.focus.macToPhone") {
            guard INFocusStatusCenter.default.authorizationStatus == .authorized else { return "Allow Focus Status access for DroidMirror Notifications" }
            guard INFocusStatusCenter.default.focusStatus.isFocused != nil else { return "Mac Focus status is not shared" }
        }
        return "Focus sync connected (3-second polling)"
    }
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }
    func connected() { gate.reset(); phoneGate.reset(); canSetPhone = nil; token = nil; tick() }
    func stop() { timer?.invalidate(); timer = nil; process?.terminate() }
    private func tick() {
        prefs.synchronize() // Settings are written by the separate host process.
        let sending = prefs.bool(forKey: "DroidMirror.focus.macToPhone")
        let receiving = prefs.bool(forKey: "DroidMirror.focus.phoneToMac")
        if sending != wasSending { gate.reset(); wasSending = sending }
        if receiving != wasReceiving {
            phoneGate.reset(); wasReceiving = receiving
            if !receiving { process?.terminate(); process = nil }
        }
        let names = ["DroidMirror.focus.onShortcut", "DroidMirror.focus.offShortcut"].map { prefs.string(forKey: $0) ?? "" }
        if names != shortcutNames { shortcutNames = names; phoneGate.reset() }
        let now = ProcessInfo.processInfo.systemUptime
        if let process, !process.isRunning {
            if process.terminationStatus != 0 { lastError = "Shortcut failed (exit \(process.terminationStatus))" }
            self.process = nil
        }
        if let process, now > processDeadline { process.terminate(); self.process = nil; lastError = "Shortcut timed out" }
        guard controller?.authenticated == true, controller?.supportsFocusSync == true else { return }
        if sending && !requestedAuthorization && INFocusStatusCenter.default.authorizationStatus == .notDetermined {
            requestedAuthorization = true
            INFocusStatusCenter.default.requestAuthorization { _ in }
        }
        // Publish Mac baseline before querying phone when both directions start together.
        defer { if sending || receiving { _ = controller?.send(["type": "focusQuery"]) } }
        guard sending else { return }
        guard INFocusStatusCenter.default.authorizationStatus == .authorized,
              let focused = INFocusStatusCenter.default.focusStatus.isFocused else { gate.reset(); return }
        guard gate.observe(focused, now: now) else { return }
        let id = UUID().uuidString
        if controller?.send(["type": "focusSet", "focused": focused, "origin": id]) == true { token = id }
        else { gate.reset() }
    }
    func receive(_ event: [String: Any]) {
        if let allowed = event["canSet"] as? Bool {
            if allowed && canSetPhone == false { gate.reset() }
            canSetPhone = allowed
            if allowed && ["disabled", "policyAccessRequired"].contains(lastError) { lastError = "" }
        }
        if let error = event["error"] as? String, !error.isEmpty {
            lastError = error
            NSLog("DroidMirror Focus sync: %@", error)
        }
        guard event["type"] as? String == "focusState", prefs.bool(forKey: "DroidMirror.focus.phoneToMac"),
              event["available"] as? Bool == true, let focused = event["focused"] as? Bool else { return }
        guard process == nil else { return }
        guard phoneGate.shouldApply(focused, origin: event["origin"] as? String, localOrigin: token) else { return }
        let key = focused ? "DroidMirror.focus.onShortcut" : "DroidMirror.focus.offShortcut"
        guard let name = prefs.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", name]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do {
            try task.run(); process = task; lastError = ""
            processDeadline = ProcessInfo.processInfo.systemUptime + 15
            gate.expect(focused, now: ProcessInfo.processInfo.systemUptime)
        } catch { lastError = "Shortcut could not start"; NSLog("DroidMirror Focus Shortcut could not start: %@", error.localizedDescription) }
    }
    deinit { stop() }
}
