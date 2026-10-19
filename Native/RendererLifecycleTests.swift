import AppKit
import Foundation

@MainActor
private final class RendererProbe: NSObject {
    var windows: [Int] = []
    var title = ""
    var framesVisible = 0
    var connectingVisible = 0
    var behavior: NSWindow.CollectionBehavior = []
    var level = -1
    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        let host = String(ProcessInfo.processInfo.processIdentifier)
        center.addObserver(self, selector: #selector(connecting(_:)), name: Notification.Name("app.droidmirror.connectingVisible"), object: host)
        center.addObserver(self, selector: #selector(visible(_:)), name: Notification.Name("app.droidmirror.mirrorVisible"), object: host)
        center.addObserver(self, selector: #selector(ended(_:)), name: Notification.Name("app.droidmirror.streamEnded"), object: host)
        center.addObserver(self, selector: #selector(presented(_:)), name: Notification.Name("app.droidmirror.presentationApplied"), object: host)
    }
    @objc func connecting(_ note: Notification) { connectingVisible += 1 }
    @objc func visible(_ note: Notification) { framesVisible += 1 }
    @objc func ended(_ note: Notification) { windows.append((note.userInfo?["window"] as? NSNumber)?.intValue ?? 0) }
    @objc func presented(_ note: Notification) {
        title = note.userInfo?["title"] as? String ?? ""
        behavior = NSWindow.CollectionBehavior(rawValue: (note.userInfo?["behavior"] as? NSNumber)?.uintValue ?? 0)
        level = (note.userInfo?["level"] as? NSNumber)?.intValue ?? -1
    }
}

@MainActor
private final class ControllerQuitProbe: NSObject, NSApplicationDelegate {
    var requested = false
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quitRequested(_:)),
            name: Notification.Name("app.droidmirror.quit"), object: String(ProcessInfo.processInfo.processIdentifier))
    }
    @objc private func quitRequested(_ note: Notification) { requested = true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requested = true
        return .terminateCancel // Test the request without terminating this harness.
    }
}

@main
struct RendererLifecycleTests {
    @MainActor
    static func main() throws {
        let quitProbe = ControllerQuitProbe()
        NSApplication.shared.delegate = quitProbe
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "printf 'DROIDMIRROR_LOCAL_USE\\n'; printf 'final diagnostic\\n' >&2"]
        let captured = ProcessDiagnostics()
        captured.attach(to: writer, captureOutput: true)
        try writer.run()
        writer.waitUntilExit()
        let finalOutput = captured.finish()
        precondition(finalOutput.contains("DROIDMIRROR_LOCAL_USE") && finalOutput.contains("final diagnostic"),
                     "Final stdout/stderr markers must be drained before session classification")
        let probe = RendererProbe()
        let renderer = MirrorRenderer.shared
        try renderer.prepare()
        defer { renderer.shutdown() }
        let pid = renderer.processIdentifier
        wait("renderer launch") { !probe.title.isEmpty }
        guard let app = NSRunningApplication(processIdentifier: pid) else { fatalError("Renderer did not register with macOS") }
        precondition(app.localizedName == "DroidMirror", "The helper must use the DroidMirror app name")
        precondition(app.activationPolicy == .regular, "The phone viewer must own the app menu and normal Stage Manager behavior")
        precondition(NSApp.activationPolicy() == .accessory, "Only the viewer gets a Dock tile")
        precondition(probe.behavior.contains([.primary, .managed, .participatesInCycle]))
        precondition(!probe.behavior.contains(.canJoinAllApplications) && !probe.behavior.contains(.auxiliary))
        precondition(probe.level == NSWindow.Level.normal.rawValue)
        renderer.focus()
        wait("viewer activation") { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        wait("viewer menu ownership") { app.ownsMenuBar }
        wait("viewer launch completion") { app.isFinishedLaunching }

        for attempt in 1...2 {
            let session = MirrorSession()
            session.arguments = ["--external-video-port=1", "--window-title=DroidMirror — Test",
                                 "--no-control", "--no-audio", "--pause-on-exit=false"]
            try session.run()
            wait("failed stream \(attempt)") { !session.isRunning }
            precondition(session.terminationStatus != 0)
            precondition(renderer.isRunning && renderer.processIdentifier == pid,
                         "A failed stream must keep the renderer process alive")
            wait("stream end notification") { probe.windows.count >= attempt }
            precondition(probe.windows.last! > 0)
            renderer.present(title: attempt == 1 ? "Connection failed" : "Phone is in use",
                             message: "Lock your phone, then connect again.")
            wait("inline presentation") { probe.title == (attempt == 1 ? "Connection failed" : "Phone is in use") }
            precondition(NSApplication.shared.modalWindow == nil)
            precondition(SettingsWindowController.shared.window == nil)
        }
        if CommandLine.arguments.count > 1 {
            let live = MirrorSession()
            live.environment = ["DROIDMIRROR_TRANSPORT": "bluetooth-classic"]
            live.arguments = ["--external-video-port=\(CommandLine.arguments[1])", "--window-title=DroidMirror — Test",
                              "--no-control", "--no-audio", "--pause-on-exit=false"]
            try live.run()
            wait("rendered video") { probe.framesVisible > 0 }
            wait("video disconnection") { !live.isRunning }
            wait("live stream end") { probe.windows.count == 3 }
            precondition(renderer.isRunning && renderer.processIdentifier == pid)
            renderer.present(title: "Disconnected", message: "Connect again when you’re ready.")
            wait("inline disconnect after video") { probe.title == "Disconnected" }
            let retry = MirrorSession()
            retry.arguments = ["--external-video-port=1", "--no-control", "--no-audio", "--pause-on-exit=false"]
            try retry.run()
            wait("retry after video") { !retry.isRunning }
            wait("retry end") { probe.windows.count == 4 }
        }
        let inactive = MirrorSession()
        inactive.arguments = ["--external-video-port=1", "--no-control", "--no-audio", "--pause-on-exit=false"]
        inactive.environment = ["DROIDMIRROR_START_GATE": "/private/tmp/DroidMirror-never-approved-" + UUID().uuidString]
        let previousConnectingCount = probe.connectingVisible
        try inactive.run()
        wait("inactivity session window") { probe.connectingVisible > previousConnectingCount }
        renderer.present(title: "Stopped due to inactivity", message: "Reconnect when you’re ready to use your phone again.")
        wait("inline inactivity") { probe.title == "Stopped due to inactivity" }
        inactive.interrupt()
        wait("inactivity stop") { !inactive.isRunning }
        precondition(inactive.terminationStatus == 0 && renderer.isRunning)
        precondition(probe.title == "Stopped due to inactivity", "Stopping a stream must preserve its inactivity notice")
        let cancelled = MirrorSession()
        cancelled.arguments = inactive.arguments
        cancelled.environment = inactive.environment
        try cancelled.run()
        cancelled.interrupt()
        wait("immediate cancellation") { !cancelled.isRunning }
        precondition(cancelled.terminationStatus == 0 && renderer.isRunning)
        precondition(probe.behavior.contains([.primary, .managed, .participatesInCycle]),
                     "Viewer classification must survive streaming, errors and retries")
        precondition(Set(probe.windows).count == 1, "Reconnects must reuse the exact NSWindow")
        renderer.focus()
        precondition(renderer.isRunning)
        if ProcessInfo.processInfo.environment["DROIDMIRROR_TEST_PREVIEW"] == "1" {
            renderer.present(title: "Phone is in use", message: "Lock your phone, then connect again.")
            print("PREVIEW_BUNDLE=" + Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DroidMirror Renderer.app").path)
            fflush(stdout)
            let deadline = Date(timeIntervalSinceNow: 150)
            let done = ProcessInfo.processInfo.environment["DROIDMIRROR_TEST_PREVIEW_DONE"]
            while Date() < deadline {
                if let done, FileManager.default.fileExists(atPath: done) { break }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
        renderer.shutdown()
        wait("renderer shutdown") { !renderer.isRunning }
        precondition(!quitProbe.requested, "Controller-initiated cleanup must not request another Quit")
        try renderer.prepare()
        let dockPID = renderer.processIdentifier
        wait("new viewer activation") { NSWorkspace.shared.frontmostApplication?.processIdentifier == dockPID }
        guard let dockApp = NSRunningApplication(processIdentifier: dockPID) else { fatalError("Missing viewer") }
        // SDL may defer the AppleEvent response while forwarding controller
        // cleanup. Verify the completed effect rather than its immediate reply.
        wait("new viewer launch completion") { dockApp.isFinishedLaunching }
        _ = dockApp.terminate()
        wait("Dock Quit forwarded to controller") { quitProbe.requested }
        wait("Dock Quit closes viewer") { !renderer.isRunning }
        print("PASS: failed streams, real decoded frames, disconnection, retries and phone-use messages share one persistent window and process; DroidMirror foreground app/menu ownership, primary managed viewer, one public Dock app, no alerts or Settings")
    }

    @MainActor
    private static func wait(_ label: String, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        precondition(condition(), "Timed out waiting for \(label)")
    }
}
