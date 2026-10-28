import AppKit
import CryptoKit
import UserNotifications
import Darwin

final class AndroidNotificationBridge {
    weak var controller: BLEController?
    private let activities = AndroidActivityMenu()
    private let activityImages = ActivityImages()
    private let center = UNUserNotificationCenter.current()
    private var categories = [String: UNNotificationCategory]()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var actions = NotificationActionQueue()
    private var conversations = NotificationConversationState()
    private var visible = false
    private var lastStart = Date.distantPast
    private let policy = NotificationDeliveryPolicy()
    private var sessionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private let activityPreferences = ActivityAppPreferences(defaults: NotificationRuntime.preferences)
    private let appPreferences = NotificationAppPreferences(defaults: NotificationRuntime.preferences)
    private var sourcePackages = [String: String]()
    private var sessionPID: pid_t?
    private var received = 0, suppressed = 0, submitted = 0, accepted = 0
    private var authorization = -1
    private var pendingDeliveries = [String: UUID]()
    private var deliveryIdentifiers = [String: String]()
    private var restorations = [String: UUID]()
    private var iconsAttached = 0
    private var focusPolicy = NotificationFocusPolicy()
    private var presentation = NotificationPresentationPolicy()
    private var dismissals = NotificationDismissalQueue()
    private static let fallbackCategory = "DroidMirror.dismiss"
    var diagnostics: String {
        "activities=\(activities.count) received=\(received) suppressed=\(suppressed) submitted=\(submitted) accepted=\(accepted) icons=\(iconsAttached) authorization=\(authorization)"
    }
    init() {
        activityImages.request = { [weak self] command, reply in
            guard let controller = self?.controller, controller.authenticated, controller.supportsActivityImages else { reply(nil); return }
            let type = command["type"] as? String == "activityImageRequest" ? "activityImageChunk" : "activityImageManifest"
            controller.request(command, expecting: type, timeout: 12) { outcome in
                if case .response(let response) = outcome { reply(response) } else { reply(nil) }
            }
        }
        activityImages.onUpdate = { [weak self] event in
            guard let self, self.controller?.authenticated == true, self.activityPreferences.allows(event) else { return }
            self.activities.update(event)
        }
        activities.onAction = { [weak self] event, action in
            guard let self, self.activityPreferences.allows(event), self.controller?.authenticated == true,
                  let phone = BLETrust.identity, let id = event["id"] as? String,
                  let version = event["version"] as? String else { return }
            let opensApp = action == "open" || (event["actions"] as? [[String: Any]] ?? []).contains {
                $0["id"] as? String == action && $0["opensApp"] as? Bool == true
            }
            let spec = action == "open" ? ["id": "open"] :
                (event["actions"] as? [[String: Any]] ?? []).first { $0["id"] as? String == action }
            self.actions.enqueue(phone: phone, command: ["type": "action", "id": id, "version": version,
                "action": action, "opensApp": opensApp, "request": UUID().uuidString], activitySpec: spec)
            if opensApp {
                self.focusPolicy = NotificationFocusPolicy()
                self.visible = false
            }
            self.flush()
        }

        categories[Self.fallbackCategory] = NotificationDismissalCategory.make(identifier: Self.fallbackCategory, actions: [])
        center.setNotificationCategories(Set(categories.values))
        center.getDeliveredNotifications { [weak self] notifications in
            DispatchQueue.main.async {
                guard let self else { return }
                for notification in notifications {
                    let info = notification.request.content.userInfo
                    guard let phone = info["phone"] as? String, let id = info["id"] as? String,
                          phone == BLETrust.identity else { continue }
                    guard let card = info["card"] as? String,
                          let event = info["cardEvent"] as? [String: Any] else {
                        self.center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
                        continue
                    }
                    self.recordApp(event)
                    guard self.appPreferences.allows(event) else {
                        self.center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
                        continue
                    }
                    self.conversations.adopt(phone: phone, card: card, source: id, event: event,
                        message: info["cardMessage"] as? [String: Any], replies: info["cardReplies"] as? [[String: Any]] ?? [])
                    let key = phone + ":" + card
                    if self.deliveryIdentifiers[key] == nil { self.deliveryIdentifiers[key] = notification.request.identifier }
                }
            }
        }
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
                if !active { self.visible = false }
            }
        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NotificationAppPreferences.changed, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.applyAppPreferences()
                if self.controller?.authenticated == true { _ = self.controller?.send(["type": "subscribe", "activityDeltas": 1]) }
            }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.flush() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit {
        stop()
    }
    func stop() {
        activityImages.reset()
        activities.clear()
        timer?.invalidate()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let sessionObserver { DistributedNotificationCenter.default().removeObserver(sessionObserver) }
        if let configurationObserver { DistributedNotificationCenter.default().removeObserver(configurationObserver) }
        configurationObserver = nil
        observer = nil; actions = NotificationActionQueue(); conversations = NotificationConversationState()
        controller = nil; pendingDeliveries.removeAll()
        restorations.removeAll()
        sourcePackages.removeAll()
    }
    private var activityMembership = ActivitySnapshotMembership()
    private var activityPhone: String?
    func connected() {
        let phone = BLETrust.identity
        if activityPhone != phone { activityImages.reset(); activities.clear() }
        activityPhone = phone
        activityMembership = ActivitySnapshotMembership()
        flush()
    }
    func resetActivities() { activityImages.reset(); activities.clear(); activityMembership = ActivitySnapshotMembership(); activityPhone = nil }
    func disconnected() { activityImages.suspend(); activityMembership = ActivitySnapshotMembership(); activities.suspend() }

    private func recordApp(_ event: [String: Any]) {
        if appPreferences.record(event) {
            NotificationRuntime.post(NotificationAppPreferences.catalogChanged.rawValue)
        }
        if let id = event["id"] as? String, let package = event["package"] as? String {
            sourcePackages[id] = package
        }
    }
    private func applyAppPreferences() {
        NotificationRuntime.preferences.synchronize()
        activities.removeDisallowed { event in
            let allowed = activityPreferences.allows(event)
            if !allowed, let id = event["id"] as? String { activityImages.remove(id) }
            return allowed
        }
        let excluded = appPreferences.excluded
        for (id, package) in sourcePackages where excluded.contains(package) { remove(id) }
        // Include cards retained by macOS across receiver restarts. Never send
        // a phone dismissal for a local app preference change.
        center.getDeliveredNotifications { [weak self] notifications in
            DispatchQueue.main.async {
                guard let self else { return }
                let identifiers = notifications.compactMap { notification -> String? in
                    let info = notification.request.content.userInfo
                    guard info["phone"] as? String != nil,
                          let event = info["cardEvent"] as? [String: Any],
                          !self.appPreferences.allows(event) else { return nil }
                    return notification.request.identifier
                }
                self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
    private func baseIdentifier(_ id: String) -> String { "DroidMirror.android.\(BLETrust.identity ?? "unpaired").\(id)" }
    private func identifier(_ id: String) -> String {
        deliveryIdentifiers[(BLETrust.identity ?? "unpaired") + ":" + id] ?? baseIdentifier(id)
    }
    func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "activitiesReset":
            if event["ids"] != nil {
                if let ids = activityMembership.accept(event) { activityImages.reconcile(ids); activities.reconcile(ids) }
            } else { activityImages.suspend(); activities.suspend() }
        case "dismissResult":
            if let request = event["request"] as? String { dismissals.acknowledged(request) }
        case "actionResult":
            guard let request = event["request"] as? String, actions.acknowledge(request) else { return }
            let success = event["success"] as? Bool == true
            if let id = conversations.status(request: request, success ? .sent : .failed) { restoreConversation(id) }
            if !success { failure("This notification action is unavailable. Unlock your phone or use the Android app.") }
        case "removed":
            guard let id = event["id"] as? String else { return }
            remove(id)
        case "notification":
            received += 1
            if AndroidActivityMenu.isActivity(event) {
                guard let phone = BLETrust.identity else { return }
                if actions.refreshActivity(phone: phone, event: event) {
                    failure("This live activity action changed while mirroring connected. Choose the action again.")
                }
                // Remove any ordinary banner when the same notification becomes persistent.
                if let id = event["id"] as? String { remove(id, includeActivity: false) }
                if activityPreferences.record(event) {
                    NotificationRuntime.post(ActivityAppPreferences.catalogChanged.rawValue)
                }
                if activityPreferences.allows(event) { activities.update(activityImages.observe(event)) }
                else if let id = event["id"] as? String { activityImages.remove(id); activities.remove(id) }
                return
            }
            if let id = event["id"] as? String { activityImages.remove(id); activities.remove(id) }
            // Deliver live events even while the mirror host is running.
            guard policy.shouldDeliver(event: event) else {
                suppressed += 1
                if let id = event["id"] as? String { remove(id) }
                return
            }
            recordApp(event)
            guard appPreferences.allows(event) else {
                suppressed += 1
                if let id = event["id"] as? String { remove(id) }
                return
            }
            guard let identity = BLETrust.identity, let source = event["id"] as? String else { return }
            let existing = Set(conversations.siblings(source))
            for card in conversations.update(event, phone: identity) {
                // Incoming messages create cards; token/echo updates must not
                // replace retained cards or race a pending reply restoration.
                if event["isMessage"] as? Bool == true && existing.contains(card) { continue }
                if restorations[card] != nil { continue }
                if let content = conversations.event(phone: identity, card: card) {
                    deliver(content)
                }
            }
        default: break
        }
    }
    private func deliver(_ event: [String: Any], forceQuiet: Bool = false) {
            guard appPreferences.allows(event) else { return }
            guard let id = event["id"] as? String, let card = event["card"] as? String, let version = event["version"] as? String,
                  let identity = BLETrust.identity else { return }
            let content = UNMutableNotificationContent()
            content.title = NotificationConversationContent.title(event)
            content.subtitle = NotificationConversationContent.subtitle(event)
            content.body = NotificationConversationContent.body(event)
            if event["isMessage"] as? Bool == true { content.threadIdentifier = identity + ":" + id }
            let storedKeys = ["id", "version", "package", "app", "title", "subtitle", "body", "conversation", "isMessage", "actions"]
            let storedEvent = event.filter { storedKeys.contains($0.key) }
            content.userInfo = ["phone": identity, "id": id, "version": version, "card": card, "cardEvent": storedEvent,
                "cardReplies": event["cardReplies"] ?? []]
            if let message = event["cardMessage"] { content.userInfo["cardMessage"] = message }
            var presentationEvent = event
            presentationEvent["id"] = card
            let quiet = presentation.quiet(identity: identity, event: presentationEvent) || forceQuiet
            content.userInfo["quiet"] = quiet
            content.interruptionLevel = quiet ? .passive : .active
            let specifications = Array((event["actions"] as? [[String: Any]] ?? []).prefix(3))
            let data = (try? JSONSerialization.data(withJSONObject: specifications, options: [.sortedKeys])) ?? Data()
            let categoryID = "DroidMirror.actions." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let actions: [UNNotificationAction] = specifications.compactMap { action in
                guard let actionID = action["id"] as? String, let title = action["title"] as? String else { return nil }
                if action["reply"] as? Bool == true {
                    return UNTextInputNotificationAction(identifier: actionID, title: title, options: [.authenticationRequired],
                        textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
                }
                return UNNotificationAction(identifier: actionID, title: title, options: [.foreground, .authenticationRequired])
            }
            if categories[categoryID] == nil && categories.count < 128 {
                categories[categoryID] = NotificationDismissalCategory.make(identifier: categoryID, actions: actions)
                center.setNotificationCategories(Set(categories.values))
            }
            content.categoryIdentifier = categories[categoryID] != nil ? categoryID : Self.fallbackCategory
            let icon = NotificationIconAttachment.makeContent(event["contentImage"] as? String)
            if let icon { content.attachments = [icon.attachment]; iconsAttached += 1 }
            let token = UUID()
            pendingDeliveries[card] = token
            NotificationCommunicationContent.prepare(content, event: event, identity: identity) { [weak self] presented in
                guard let self, self.pendingDeliveries[card] == token, BLETrust.identity == identity,
                      self.appPreferences.allows(event) else {
                    if let icon { try? FileManager.default.removeItem(at: icon.directory) }
                    return
                }
                self.pendingDeliveries.removeValue(forKey: card)
                self.submitted += 1
                self.center.add(UNNotificationRequest(identifier: self.identifier(card), content: presented, trigger: nil)) { [weak self] error in
                    if let error { NSLog("DroidMirror notification delivery failed: %@", error.localizedDescription) }
                    else { DispatchQueue.main.async {
                        guard let self else { return }
                        self.accepted += 1
                        if !self.appPreferences.allows(event) { self.applyAppPreferences() }
                    } }
                    if let icon { try? FileManager.default.removeItem(at: icon.directory) }
                }
            }
    }
    private func restoreConversation(_ id: String) {
        // Wait until the response completion has let macOS dismiss its old card.
        // Fetch the latest state at execution time so a phone update wins races.
        let phone = BLETrust.identity
        let token = UUID()
        restorations[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.restorations[id] == token, let phone, BLETrust.identity == phone,
                  let event = self.conversations.event(phone: phone, card: id) else { return }
            self.restorations.removeValue(forKey: id)
            self.deliver(event, forceQuiet: true)
        }
    }
    private func remove(_ id: String, includeActivity: Bool = true) {
        if includeActivity { activityImages.remove(id) }
        if includeActivity { activities.remove(id) }
        sourcePackages.removeValue(forKey: id)
        let cards = conversations.remove(id)
        for card in cards {
            restorations.removeValue(forKey: card)
            pendingDeliveries.removeValue(forKey: card)
            center.removePendingNotificationRequests(withIdentifiers: [identifier(card)])
            center.removeDeliveredNotifications(withIdentifiers: [identifier(card)])
            deliveryIdentifiers.removeValue(forKey: (BLETrust.identity ?? "unpaired") + ":" + card)
        }
        center.removeDeliveredNotifications(withIdentifiers: [baseIdentifier(id)])
        dismissals.removed(id: id)
        actions.removed(id: id)
    }
    func respond(_ response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        if let event = info["cardEvent"] as? [String: Any], !appPreferences.allows(event) { return }
        guard let identity = info["phone"] as? String, identity == BLETrust.identity,
              let id = info["id"] as? String, let card = info["card"] as? String,
              let originalVersion = info["version"] as? String else { return }
        let current = conversations.currentSource(phone: identity, id: id)
        let version = current?["version"] as? String ?? originalVersion
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            // Ignore a late dismissal for the old card after a reply rotated it.
            guard response.notification.request.identifier == identifier(card) else { return }
            conversations.dismiss(card)
            restorations.removeValue(forKey: card)
            pendingDeliveries.removeValue(forKey: card)
            deliveryIdentifiers.removeValue(forKey: identity + ":" + card)
            // Android has one source notification for the whole conversation.
            // Preserve siblings until the final Mac card is dismissed.
            if conversations.siblings(id).isEmpty { dismissals.enqueue(phone: identity, id: id, version: version) }
            flush()
            return
        }
        var selectedAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier
        if selectedAction != "open", let current {
            let original = (info["cardEvent"] as? [String: Any])?["actions"] as? [[String: Any]] ?? []
            let latest = current["actions"] as? [[String: Any]] ?? []
            guard let chosen = original.first(where: { $0["id"] as? String == selectedAction }),
                  let match = latest.first(where: { $0["title"] as? String == chosen["title"] as? String &&
                      ($0["reply"] as? Bool == true) == (chosen["reply"] as? Bool == true) }),
                  let actionID = match["id"] as? String else {
                failure("This notification action is no longer available on your phone."); return
            }
            selectedAction = actionID
        }
        let request = UUID().uuidString
        var command: [String: Any] = ["type": "action", "id": id, "version": version,
            "action": selectedAction, "request": request]
        if let reply = response as? UNTextInputNotificationResponse {
            let text = String(reply.userText.prefix(1024))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            command["text"] = text
            let previous = identifier(card)
            deliveryIdentifiers[identity + ":" + card] = baseIdentifier(card) + ".reply." + UUID().uuidString
            center.removeDeliveredNotifications(withIdentifiers: [previous])
            if let outgoing = conversations.reply(phone: identity, card: card, request: request, text: text) {
                restoreConversation(card)
                restoreConversation(outgoing)
            }
        }
        actions.enqueue(phone: identity, command: command)
        if command["action"] as? String == "open" {
            focusPolicy = NotificationFocusPolicy()
            visible = false
            controller?.requestEndpoint(); controller?.connectADB()
        }
        flush()
    }
    func flush() {
        activities.tick()
        if let identity = BLETrust.identity, controller?.authenticated == true {
            for command in dismissals.due(phone: identity) {
                if controller?.send(command) == true, let request = command["request"] as? String {
                    dismissals.sent(request)
                }
            }
        }
        for expired in actions.expire(phone: BLETrust.identity) {
            if let request = expired.command["request"] as? String,
               let id = conversations.status(request: request, expired.sent ? .unconfirmed : .failed) { restoreConversation(id) }
            failure(expired.sent ? "Your phone hasn’t confirmed the notification action. Check the conversation before trying again."
                : "Couldn’t connect to your phone. The notification action was not sent.")
        }
        guard let identity = BLETrust.identity else { return }
        // An explicit click focuses immediately, even if a recent reconnect
        // throttles startup or a visible heartbeat arrives before the next flush.
        if actions.needsMirror(phone: identity), focusPolicy.requestOnce() {
            lastStart = Date()
            if NotificationRuntime.background { NotificationRuntime.requestMirror() }
            else if let function = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DroidMirrorRequestMirror") {
                unsafeBitCast(function, to: (@convention(c) () -> Void).self)()
            }
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.droidmirror.focusMirror"),
                object: sessionPID.map { String($0) }, userInfo: nil, deliverImmediately: true)
        }
        for pending in actions.due(phone: identity, mirrorVisible: visible) {
            if controller?.send(pending.command) == true, let request = pending.command["request"] as? String {
                // Never resend an unacknowledged reply: it could send twice.
                actions.sent(request)
            }
        }
        if !visible && actions.needsMirror(phone: identity) {
            if Date().timeIntervalSince(lastStart) >= 2 {
                lastStart = Date()
                // Host owns launch/cleanup; never start an unmanaged second client.
                if NotificationRuntime.background { NotificationRuntime.requestMirror(activate: false) }
            }
            return
        }
    }
    private func failure(_ text: String) {
        let content = UNMutableNotificationContent(); content.title = "DroidMirror"; content.body = text
        center.add(UNNotificationRequest(identifier: "DroidMirror.actionFailure", content: content, trigger: nil))
    }
}
