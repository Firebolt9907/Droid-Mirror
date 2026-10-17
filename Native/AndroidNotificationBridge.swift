import AppKit
import CryptoKit
import UserNotifications
import Darwin

final class AndroidNotificationBridge {
    weak var controller: BLEController?
    private let center = UNUserNotificationCenter.current()
    private var categories = [String: UNNotificationCategory]()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var pending: (command: [String: Any], expires: Date)?
    private var visible = false
    private var lastStart = Date.distantPast
    private var policy = NotificationDeliveryPolicy()
    private var sessionObserver: NSObjectProtocol?
    private var sessionPID: pid_t?
    private var received = 0, suppressed = 0, submitted = 0, accepted = 0
    private var authorization = -1
    private var iconsAttached = 0
    private var focusPolicy = NotificationFocusPolicy()
    private var presentation = NotificationPresentationPolicy()
    var diagnostics: String {
        "received=\(received) suppressed=\(suppressed) submitted=\(submitted) accepted=\(accepted) icons=\(iconsAttached) authorization=\(authorization)"
    }
    init() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.authorization = settings.authorizationStatus.rawValue }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.droidmirror.mirrorVisible"),
            object: nil, queue: .main) { [weak self] event in
                guard let value = event.object as? String, let pid = Int32(value),
                      NotificationRuntime.isHost(pid: pid) else { return }
                self?.visible = true; self?.flush()
            }
        sessionObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.droidmirror.sessionState"), object: nil, queue: .main) { [weak self] event in
                guard let self, let value = event.userInfo?["pid"] as? Int, let pid = Int32(exactly: value),
                      NotificationRuntime.isHost(pid: pid),
                      let active = event.userInfo?["active"] as? Bool else { return }
                self.sessionPID = pid
                self.policy.session(active: active)
                if !active { self.visible = false }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.flush() }
    }
    deinit {
        stop()
    }
    func stop() {
        timer?.invalidate()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let sessionObserver { DistributedNotificationCenter.default().removeObserver(sessionObserver) }
        observer = nil; pending = nil; controller = nil
    }
    private func identifier(_ id: String) -> String { "DroidMirror.android.\(BLETrust.identity ?? "unpaired").\(id)" }
    func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "actionResult":
            if event["success"] as? Bool != true { failure("This notification action is unavailable. Unlock your phone or use the Android app.") }
        case "removed":
            guard let id = event["id"] as? String else { return }
            center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
            center.removeDeliveredNotifications(withIdentifiers: [identifier(id)])
            if pending?.command["id"] as? String == id { pending = nil }
        case "notification":
            received += 1
            // Do not queue suppressed notifications for later: that would replay
            // everything the user already saw on the mirrored phone.
            let hostIsRunning = NotificationRuntime.host != nil
            // Absence of the host always wins, including when no heartbeat was
            // received. Comparing two nil PIDs previously left suppression stuck.
            policy.reconcile(hostIsRunning: hostIsRunning,
                hasSessionState: sessionPID.map { NotificationRuntime.isHost(pid: $0) } == true)
            guard policy.shouldDeliver() else { suppressed += 1; return }
            guard let id = event["id"] as? String, let version = event["version"] as? String,
                  let identity = BLETrust.identity else { return }
            let content = UNMutableNotificationContent()
            content.title = String((event["app"] as? String ?? "Android").prefix(120))
            content.subtitle = String((event["title"] as? String ?? "").prefix(240))
            content.body = String((event["body"] as? String ?? "").prefix(1200))
            content.userInfo = ["phone": identity, "id": id, "version": version]
            let quiet = presentation.quiet(identity: identity, event: event)
            content.userInfo["quiet"] = quiet
            content.interruptionLevel = quiet ? .passive : .active
            let specifications = Array((event["actions"] as? [[String: Any]] ?? []).prefix(3))
            let data = (try? JSONSerialization.data(withJSONObject: specifications, options: [.sortedKeys])) ?? Data()
            let categoryID = "DroidMirror.actions." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let actions: [UNNotificationAction] = specifications.compactMap { action in
                guard let actionID = action["id"] as? String, let title = action["title"] as? String else { return nil }
                if action["reply"] as? Bool == true {
                    return UNTextInputNotificationAction(identifier: actionID, title: title, options: [.foreground, .authenticationRequired],
                        textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
                }
                return UNNotificationAction(identifier: actionID, title: title, options: [.foreground, .authenticationRequired])
            }
            if categories[categoryID] == nil && categories.count < 128 {
                categories[categoryID] = UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: [])
                center.setNotificationCategories(Set(categories.values))
            }
            if categories[categoryID] != nil { content.categoryIdentifier = categoryID }
            let icon = NotificationIconAttachment.make(event["appIcon"] as? String)
            if let icon { content.attachments = [icon.attachment]; iconsAttached += 1 }
            submitted += 1
            center.add(UNNotificationRequest(identifier: identifier(id), content: content, trigger: nil)) { [weak self] error in
                if let error { NSLog("DroidMirror notification delivery failed: %@", error.localizedDescription) }
                else { DispatchQueue.main.async { self?.accepted += 1 } }
                // Only remove our staging directory. macOS owns its attachment copy.
                if let icon { try? FileManager.default.removeItem(at: icon.directory) }
            }
        default: break
        }
    }
    func respond(_ response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let identity = info["phone"] as? String, identity == BLETrust.identity,
              let id = info["id"] as? String, let version = info["version"] as? String else { return }
        var command: [String: Any] = ["type": "action", "id": id, "version": version,
            "action": response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier,
            "request": UUID().uuidString]
        if let reply = response as? UNTextInputNotificationResponse { command["text"] = String(reply.userText.prefix(1024)) }
        pending = (command, Date().addingTimeInterval(45))
        focusPolicy = NotificationFocusPolicy()
        visible = false
        controller?.requestEndpoint(); controller?.connectADB()
        flush()
    }
    func flush() {
        guard let pending else { return }
        guard pending.expires > Date() else { self.pending = nil; failure("Couldn’t connect to your phone. The notification action was not sent."); return }
        if !visible {
            if Date().timeIntervalSince(lastStart) >= 2 {
                lastStart = Date()
                let focus = focusPolicy.requestOnce()
                // Host owns launch/cleanup; never start an unmanaged second client.
                if NotificationRuntime.background { NotificationRuntime.requestMirror(activate: focus) }
                else if focus, let function = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DroidMirrorRequestMirror") {
                    unsafeBitCast(function, to: (@convention(c) () -> Void).self)()
                }
                if focus {
                    DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.droidmirror.focusMirror"),
                        object: sessionPID.map { String($0) }, userInfo: nil, deliverImmediately: true)
                }
            }
            return
        }
        if controller?.send(pending.command) == true { self.pending = nil }
    }
    private func failure(_ text: String) {
        let content = UNMutableNotificationContent(); content.title = "DroidMirror"; content.body = text
        center.add(UNNotificationRequest(identifier: "DroidMirror.actionFailure", content: content, trigger: nil))
    }
}
