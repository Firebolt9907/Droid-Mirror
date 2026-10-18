import AppKit

/// A stream attempt inside the app's persistent, private rendering helper.
@MainActor
final class MirrorSession {
    let id = UUID().uuidString
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var terminationHandler: ((MirrorSession) -> Void)?
    private(set) var isRunning = false
    private(set) var terminationStatus: Int32 = 0
    private(set) var diagnostic = ""
    var processIdentifier: pid_t { MirrorRenderer.shared.processIdentifier }

    func run() throws {
        try MirrorRenderer.shared.start(self)
        isRunning = true
    }
    func interrupt() { MirrorRenderer.shared.stop(self) }
    func terminate() { interrupt() }
    func finish(code: Int32, diagnostic: String) {
        guard isRunning else { return }
        isRunning = false
        terminationStatus = code
        self.diagnostic = diagnostic
        terminationHandler?(self)
    }
}

@MainActor
final class MirrorRenderer: NSObject {
    static let shared = MirrorRenderer()
    private var process: Process?
    private var session: MirrorSession?
    private var diagnostics: ProcessDiagnostics?
    private var directory: URL?
    private var heartbeat: Timer?
    private var shuttingDown = false
    private var noticeConnecting = false
    private var deviceName = "your phone"
    private var appearanceCache = ""

    func configure(device: AndroidDevice?) {
        deviceName = device?.displayName ?? "your phone"
        appearanceCache = device.map { PhoneAppearanceCache.path(for: $0) } ?? ""
        present(title: noticeTitle, message: noticeMessage, connecting: noticeConnecting)
    }
    private(set) var noticeTitle = "Ready to connect"
    private(set) var noticeMessage = "Keep your phone locked and nearby."
    var isRunning: Bool { process?.isRunning == true }
    var processIdentifier: pid_t { process?.processIdentifier ?? 0 }
    static var executablePath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/DroidMirror Renderer.app/Contents/MacOS/DroidMirrorRenderer").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sessionFinished(_:)), name: Notification.Name("app.droidmirror.streamEnded"),
            object: String(ProcessInfo.processInfo.processIdentifier))
    }

    func prepare(environment: [String: String] = [:]) throws {
        if isRunning { return }
        guard let executable = Self.executablePath else { throw RunnerError.failed("The DroidMirror renderer is missing. Rebuild the app.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-renderer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        directory = dir
        shuttingDown = false
        var childEnvironment = ToolProcessEnvironment.clean()
        childEnvironment.merge(environment) { _, value in value }
        childEnvironment["DROIDMIRROR_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        childEnvironment["DROIDMIRROR_SESSION_COMMANDS"] = dir.appendingPathComponent("command.json").path
        childEnvironment["DROIDMIRROR_SESSION_STATE"] = dir.appendingPathComponent("state.json").path
        childEnvironment["DYLD_INSERT_LIBRARIES"] = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/libDroidMirrorStyle.dylib").path
        childEnvironment["SCRCPY_ICON_DIR"] = URL(fileURLWithPath: executable)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path
        childEnvironment["SDL_APP_NAME"] = "DroidMirror"
        childEnvironment["SDL_APP_ID"] = "app.droidmirror.mac"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.environment = childEnvironment
        child.standardOutput = FileHandle.nullDevice
        let output = ProcessDiagnostics()
        output.attach(to: child, captureOutput: true)
        child.terminationHandler = { [weak self] child in
            let text = output.finish()
            Task { @MainActor in
                guard let self, self.process === child else { return }
                let active = self.session
                self.session = nil
                self.process = nil
                self.heartbeat?.invalidate()
                self.publishSessionState()
                if !self.shuttingDown {
                    active?.finish(code: child.terminationStatus == 0 ? 1 : child.terminationStatus, diagnostic: text)
                }
                try? FileManager.default.removeItem(at: dir)
                if !self.shuttingDown { PhoneWindowController.shared.rendererClosed() }
            }
        }
        do { try child.run() } catch {
            try? FileManager.default.removeItem(at: dir)
            directory = nil
            throw error
        }
        process = child
        present(title: noticeTitle, message: noticeMessage, connecting: noticeConnecting)
        diagnostics = output
        heartbeat?.invalidate()
        heartbeat = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishSessionState() }
        }
    }

    func start(_ session: MirrorSession) throws {
        guard self.session == nil else { throw RunnerError.failed("A mirror session is already running.") }
        try prepare(environment: session.environment)
        guard let directory else { throw RunnerError.failed("The renderer could not start.") }
        diagnostics?.reset()
        present(title: "Connecting…", message: "Keep your phone locked and nearby.", connecting: true)
        self.session = session
        do {
            let command: [String: Any] = ["session": session.id, "arguments": session.arguments,
                                          "environment": session.environment]
            try JSONSerialization.data(withJSONObject: command).write(
                to: directory.appendingPathComponent("command.json"), options: .atomic)
        } catch { self.session = nil; throw error }
    }

    func present(title: String, message: String, connecting: Bool = false) {
        noticeConnecting = connecting
        noticeTitle = title
        noticeMessage = message
        guard let directory else { return }
        let state: [String: Any] = ["title": title, "message": message, "connecting": connecting,
                                    "deviceName": deviceName, "appearanceCache": appearanceCache]
        try? JSONSerialization.data(withJSONObject: state).write(
            to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func focus() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.droidmirror.focusMirror"), object: String(ProcessInfo.processInfo.processIdentifier),
            userInfo: nil, deliverImmediately: true)
    }

    func stop(_ session: MirrorSession) {
        guard self.session === session else { return }
        guard let directory else { return }
        try? Data().write(to: directory.appendingPathComponent("stop." + session.id), options: .atomic)
    }

    @objc private func sessionFinished(_ notification: Notification) {
        guard let session, notification.userInfo?["session"] as? String == session.id,
              let code = notification.userInfo?["code"] as? NSNumber else { return }
        self.session = nil
        session.finish(code: code.int32Value, diagnostic: diagnostics?.snapshot() ?? "")
        publishSessionState()
    }

    private func publishSessionState() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.droidmirror.sessionState"), object: nil,
            userInfo: ["pid": ProcessInfo.processInfo.processIdentifier, "active": session?.isRunning == true],
            deliverImmediately: true)
    }

    func shutdown() {
        shuttingDown = true
        if let directory {
            try? Data().write(to: directory.appendingPathComponent("shutdown"), options: .atomic)
            try? Data("{\"quit\":true}".utf8).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        }
        session?.terminationHandler = nil
        heartbeat?.invalidate()
        if process?.isRunning == true { process?.terminate() }
    }
}
