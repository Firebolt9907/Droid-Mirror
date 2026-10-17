import AppKit
import Darwin
import SwiftUI

@MainActor
final class DroidMirrorAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false
    private var terminationCleanupComplete = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Task { await SessionNotifications.shared.requestPermission() }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(quitRequestedByMirror(_:)),
            name: NSNotification.Name("app.droidmirror.quit"),
            object: String(ProcessInfo.processInfo.processIdentifier)
        )
        MirrorModel.shared.refreshDevices()
        if MirrorModel.shared.preferences.transport != .adb {
            SettingsWindowController.shared.show(model: MirrorModel.shared)
        }
    }

    @objc private func quitRequestedByMirror(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(model: MirrorModel.shared)
    }

    @objc private func pairBluetooth(_ sender: Any?) {
        let model = MirrorModel.shared
        if !model.isMirroring && !model.isStarting {
            model.preferences.transport = .bluetoothClassic
        }
        SettingsWindowController.shared.show(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(model: MirrorModel.shared)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupComplete { return .terminateNow }
        guard !terminationInProgress else { return .terminateCancel }
        terminationInProgress = true
        Task { @MainActor in
            await MirrorModel.shared.shutdownForApplicationTermination()
            terminationCleanupComplete = true
            sender.terminate(nil)
        }
        // Keep the ordinary run loop alive while Swift's main-actor cleanup
        // runs. AppKit's deferred termination loop can starve that work.
        return .terminateCancel
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let pairingItem = NSMenuItem(title: "Pair Bluetooth…", action: #selector(pairBluetooth(_:)), keyEquivalent: "")
        pairingItem.target = self
        appMenu.addItem(pairingItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit DroidMirror",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        quitItem.keyEquivalentModifierMask = .command
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Text fields, including the BLE pairing code, need responder-chain editing
        // commands because this app owns its AppKit menu instead of a SwiftUI scene.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

@main
struct DroidMirrorMain {
    @MainActor
    static func main() {
        // Validate the actual launcher/injected-library path without initializing
        // UI, reading pairing keys, starting the receiver, or connecting a phone.
        if CommandLine.arguments.contains("--check-launch") {
            let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libDroidMirrorBLE.dylib")
            guard dlopen(library.path, RTLD_NOW | RTLD_LOCAL) != nil else {
                fputs("DroidMirror BLE library failed to load\n", stderr)
                exit(1)
            }
            print("DroidMirror launch check passed")
            return
        }
        let app = NSApplication.shared
        let delegate = DroidMirrorAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        _ = MirrorModel.shared
        app.finishLaunching()
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
