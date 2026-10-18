import AppKit
import Foundation

@main
struct SessionWindowTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let model = MirrorModel()
        let controller = PhoneWindowController.shared
        controller.show(model: model)
        precondition(controller.window?.isVisible == true, "Missing renderer must have an inline fallback")
        precondition(SettingsWindowController.shared.window == nil)
        precondition(controller.window?.styleMask.contains(.titled) == false, "Phone chrome has no traffic lights")
        model.errorMessage = "Connection failed"
        pump()
        precondition(model.sessionNoticeTitle == "Connection failed")
        precondition(model.sessionNoticeMessage == "Connection failed")
        precondition(controller.window?.isVisible == true, "Errors leave the phone window open")
        precondition(app.modalWindow == nil, "Errors must not present alerts")
        controller.reopen(model: model)
        precondition(controller.window?.isVisible == true)
        precondition(SettingsWindowController.shared.window == nil)
        SessionNotifications.shared.localUse(restored: true)
        pump()
        precondition(MirrorModel.shared.sessionNoticeTitle == "Phone is in use")
        precondition(app.modalWindow == nil && SettingsWindowController.shared.window == nil)
        model.errorMessage = nil
        let previousNotice = model.sessionNoticeTitle
        model.stopForInactivity()
        precondition(model.sessionNoticeTitle == previousNotice, "Idle windows must ignore stale inactivity timers")
        model.isMirroring = true
        model.stopForInactivity()
        precondition(model.sessionNoticeTitle == "Stopped due to inactivity")
        precondition(model.status == "Stopped due to inactivity")
        // Simulate the asynchronous transport completion after stopping.
        model.isMirroring = false
        model.status = "Mirror disconnected"
        model.presentStoppedMirror()
        pump()
        precondition(model.sessionNoticeTitle == "Stopped due to inactivity")
        precondition(model.status == "Stopped due to inactivity")
        precondition(controller.window?.isVisible == true)
        precondition(app.modalWindow == nil && SettingsWindowController.shared.window == nil)
        print("PASS: inline errors and phone-use states, persistent fallback, borderless chrome, Dock reopening and persistent inactivity reason")
    }
    @MainActor private static func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
}
