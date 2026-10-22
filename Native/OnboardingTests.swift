import AppKit
import SwiftUI

@main
struct OnboardingTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let defaults = UserDefaults.standard
        let keys = ["DroidMirror.onboarding.started", "DroidMirror.onboarding.completed", "DroidMirror.onboarding.step", "DroidMirror.BLE.enabled"]
        for key in keys { defaults.removeObject(forKey: key) }
        defer { for key in keys { defaults.removeObject(forKey: key) } }
        let model = MirrorModel()
        model.preferences.autoStart = false
        model.preferences.bluetoothDeviceID = nil
        precondition(OnboardingWindowController.needsFirstRun(model: model))
        model.preferences.bluetoothDeviceID = "test-phone"
        precondition(!OnboardingWindowController.needsFirstRun(model: model), "Existing setups must not be forced through onboarding")
        defaults.set(true, forKey: "DroidMirror.onboarding.started")
        precondition(OnboardingWindowController.needsFirstRun(model: model), "An interrupted setup must resume")
        defaults.set(true, forKey: "DroidMirror.onboarding.completed")
        precondition(!OnboardingWindowController.needsFirstRun(model: model))
        let controller = OnboardingWindowController.shared
        controller.show(model: model)
        precondition(model.isOnboarding && controller.window?.isVisible == true)
        model.bluetoothPairingCode = "test-private-value"
        controller.close()
        precondition(!model.isOnboarding && model.bluetoothPairingCode.isEmpty, "Closing clears the draft code and releases the auto-start pause")
        controller.show(model: model)
        precondition(model.isOnboarding && controller.window?.isVisible == true)
        controller.close()

        model.isOnboarding = true
        model.devices = [AndroidDevice(id: "test-phone", state: "device", model: "Android phone", product: "", transport: "bluetooth-classic")]
        model.selectedID = "test-phone"
        model.bluetoothPairingCode = "invalid-code"
        model.pairBluetooth()
        precondition(model.isPairingBluetooth)
        model.start()
        precondition(!model.isStarting, "Starting a mirror must wait for an in-flight code save")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(!model.isPairingBluetooth && model.pairingError != nil)
        precondition(model.savedPairingDeviceID == nil && model.verifiedBluetoothDeviceID == nil,
                     "An invalid code must not mark pairing or streaming verified")
        precondition(model.beginQRPairing(), "QR transfer should reserve the pairing flow")
        precondition(!model.beginQRPairing(), "Only one QR invitation may be open")
        model.start()
        precondition(!model.isStarting, "Mirroring must wait until QR pairing closes")
        model.pairBluetooth()
        precondition(model.isPairingBluetooth, "Manual entry cannot replace an open QR transfer")
        model.endQRPairing()
        precondition(!model.isPairingBluetooth, "Closing QR setup releases the connection guard")
        precondition(model.savedPairingDeviceID == nil && model.verifiedBluetoothDeviceID == nil,
                     "Opening or cancelling QR setup must not mark a key saved or a mirror verified")
        model.bluetoothPairingCode = ""
        model.pairingError = nil
        model.status = "Select your phone and continue setup"
        let output = ProcessInfo.processInfo.environment["DROIDMIRROR_ONBOARDING_PREVIEWS"] ?? "/private/tmp/droidmirror-onboarding-previews"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for step in 0..<4 {
            defaults.set(step, forKey: "DroidMirror.onboarding.step")
            let host = NSHostingController(rootView: OnboardingView().environmentObject(model)
                .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(NSSize(width: 600, height: 610))
            window.appearance = NSAppearance(named: .aqua)
            window.orderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            host.view.layoutSubtreeIfNeeded()
            let view = host.view
            precondition(view.bounds.width >= 600 && view.bounds.height >= 610)
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/mac-step-\(step + 1).png"))
            window.orderOut(nil)
        }
        print("PASS: first-run migration, interrupted setup, setup window reopening, draft-code cleanup, QR pairing guards and four rendered onboarding steps")
    }
}
