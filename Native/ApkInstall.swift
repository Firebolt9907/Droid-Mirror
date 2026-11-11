import AppKit
import LocalAuthentication
import UserNotifications

/// Validation shared by the host's Finder handler and the background receiver.
enum ApkInstallRequestPolicy {
    static var limit: Int { ApkInstallPolicy.limit }

    static func isApk(_ url: URL) -> Bool { url.isFileURL && url.pathExtension.lowercased() == "apk" }

    /// Regular, readable, non-symlink files below the transport limit.
    static func validate(_ url: URL) -> String? {
        guard isApk(url) else { return "Only .apk files can be installed on your phone." }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            return "\(url.lastPathComponent) isn’t a readable file."
        }
        guard size > 0, size < limit else { return "\(url.lastPathComponent) must be smaller than 256 MB." }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return "\(url.lastPathComponent) isn’t readable." }
        return nil
    }
}

/// Runs only in the background receiver, which owns the authenticated phone
/// connection. Every install needs an explicit confirmation plus a fresh
/// Touch ID (or Mac password) check; biometric success is never reused.
@MainActor
final class ApkInstallCoordinator {
    private weak var clipboard: ClipboardSync?
    private var queue = [URL]()
    private var active: URL?
    private var context: LAContext?

    init(clipboard: ClipboardSync?) {
        self.clipboard = clipboard
        clipboard?.installStatus = { [weak self] message, finished, succeeded in
            // Synchronous on main so a refusal from installApk is handled before it returns.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.status(message, finished: finished, succeeded: succeeded) }
            } else {
                DispatchQueue.main.async { self?.status(message, finished: finished, succeeded: succeeded) }
            }
        }
    }

    func request(_ url: URL) {
        let url = url.standardizedFileURL
        guard active != url, !queue.contains(url) else { return }
        queue.append(url)
        if active == nil { next() }
    }

    func cancel() {
        context?.invalidate()
        queue.removeAll()
    }

    private func next() {
        guard active == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        active = url
        Task { @MainActor in await self.run(url) }
    }

    private func run(_ url: URL) async {
        if let problem = ApkInstallRequestPolicy.validate(url) { return finish(failure: problem) }
        // A cold-launched receiver needs a moment to reconnect and authenticate.
        let deadline = Date().addingTimeInterval(20)
        while clipboard?.canInstallApk == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let clipboard, clipboard.canInstallApk else {
            return finish(failure: "Connect your phone with the BLE bridge, turn on clipboard mirroring, update the DroidMirror companion and make sure Shizuku is running.")
        }
        guard confirm(url) else { return done() }
        guard await authenticate(url) else { return done() }
        // Re-check after the prompts: the phone may have disconnected meanwhile.
        if let problem = ApkInstallRequestPolicy.validate(url) { return finish(failure: problem) }
        guard clipboard.canInstallApk else { return finish(failure: "Your phone disconnected before the install could start.") }
        notify("Installing \(url.lastPathComponent)", body: "Sending to your phone…", identifier: "DroidMirror.apkInstall.progress")
        // installApk reports a reason through installStatus if it can't start.
        if !clipboard.installApk(url), active == url {
            finish(failure: "The phone couldn’t start the install. Try again in a moment.")
        }
    }

    private func confirm(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "unknown size"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install “\(url.lastPathComponent)” on your phone?"
        alert.informativeText = "\(size). DroidMirror installs it with Shizuku, without asking on the phone. An app that is already installed is updated. Only install apps you trust."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Touch ID, with the Mac login password as the fallback (and on Macs without a sensor).
    private func authenticate(_ url: URL) async -> Bool {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            notify("Couldn’t install \(url.lastPathComponent)",
                   body: "This Mac can’t verify your identity: \(error?.localizedDescription ?? "authentication unavailable").",
                   identifier: "DroidMirror.apkInstall.result")
            return false
        }
        self.context = context
        defer { context.invalidate(); if self.context === context { self.context = nil } }
        NSApp.activate(ignoringOtherApps: true)
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "install “\(url.lastPathComponent)” on your Android phone")
        } catch { return false }
    }

    private func status(_ message: String, finished: Bool, succeeded: Bool) {
        guard let url = active else { return }
        if !finished {
            notify("Installing \(url.lastPathComponent)", body: message, identifier: "DroidMirror.apkInstall.progress", quiet: true)
            return
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["DroidMirror.apkInstall.progress"])
        notify(succeeded ? "Installed \(url.lastPathComponent)" : "Couldn’t install \(url.lastPathComponent)",
               body: message, identifier: "DroidMirror.apkInstall.result")
        active = nil
        next()
    }

    private func finish(failure: String) {
        if let url = active {
            notify("Couldn’t install \(url.lastPathComponent)", body: failure, identifier: "DroidMirror.apkInstall.result")
        }
        done()
    }

    private func done() {
        active = nil
        next()
    }

    private func notify(_ title: String, body: String, identifier: String, quiet: Bool = false) {
        NSLog("DroidMirror APK install: %@ — %@", title, body)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if quiet { content.userInfo = ["quiet": true] } else { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
