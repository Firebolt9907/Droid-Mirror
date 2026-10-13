import AppKit
import SwiftUI

@MainActor
final class DroidMirrorAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(quitRequestedByMirror(_:)),
            name: NSNotification.Name("app.droidmirror.quit"),
            object: String(ProcessInfo.processInfo.processIdentifier)
        )
        MirrorModel.shared.refreshDevices()
    }

    @objc private func quitRequestedByMirror(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(model: MirrorModel.shared)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateNow }
        terminationInProgress = true
        Task { @MainActor in
            await MirrorModel.shared.shutdownForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
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
        NSApp.mainMenu = mainMenu
    }
}

@main
struct DroidMirrorMain {
    @MainActor
    static func main() {
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
