import AppKit
import Combine

// Port discovery lives in DroidMirror's host process, not a second menu-bar app.
private var integration: BLEIntegration?

@_cdecl("DroidMirrorStartBLE")
public func startDroidMirrorBLE() {
    if integration == nil { integration = BLEIntegration() }
}

@_cdecl("DroidMirrorStopBLE")
public func stopDroidMirrorBLE() {
    integration?.stop()
}

@_cdecl("DroidMirrorRefreshBLEMenu")
public func refreshDroidMirrorBLEMenu() {
    integration?.refreshMenu()
}

func shareDroidMirrorLink(_ url: URL) { integration?.shareLink(url) }

private final class BLEIntegration: NSObject {
    private let links = LinkSharing()
    func shareLink(_ url: URL) { if NotificationRuntime.background { links.share(url) } }
    private var mirrorTarget = MirrorWindowCommandTarget()
    private var controller: BLEController?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var menuItem: NSMenuItem?
    private var statusItem: NSMenuItem?
    private var endpointItem: NSMenuItem?
    private var adbItem: NSMenuItem?
    private let enabledKey = "DroidMirror.BLE.enabled"
    private var discoveryNotifications: DiscoveryNotifications?
    private var phoneNotifications: AndroidNotificationBridge?
    private var media: MediaPlaybackSync?
    private var mediaItem: NSMenuItem?
    private var mediaStatusItem: NSMenuItem?
    private var remoteMediaStatus = "Media syncing off"
    private var clipboard: ClipboardSync?
    private var taskContinuation: TaskContinuation?
    private var hotspot: PhoneHotspot?
    private var clipboardItem: NSMenuItem?
    private var clipboardStatusItem: NSMenuItem?
    private var remoteClipboardStatus = "Clipboard mirroring off"
    private var menuObservers = [NSObjectProtocol]()
    private var repairingMenu = false
    private var stopped = false
    private var remoteStatus = "Starting background receiver…"
    private var remoteEndpoint = "Wireless ADB off"

    override init() {
        super.init()
        discoveryNotifications = DiscoveryNotifications(warningsEnabled: !NotificationRuntime.background)
        phoneNotifications = NotificationRuntime.background ? AndroidNotificationBridge() : nil
        media = NotificationRuntime.background ? MediaPlaybackSync() : nil
        clipboard = NotificationRuntime.background ? ClipboardSync() : nil
        taskContinuation = NotificationRuntime.background ? TaskContinuation() : nil
        hotspot = NotificationRuntime.background ? PhoneHotspot() : nil
        discoveryNotifications?.onResponse = { [weak self] response in self?.phoneNotifications?.respond(response) }
        NotificationRuntime.preferences.register(defaults: [enabledKey: true])
        if NotificationRuntime.background && NotificationRuntime.preferences.bool(forKey: enabledKey) { start() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NotificationRuntime.background { self.links.tick(); self.publishStatus() }
            else { self.refreshMenu() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        for name in [NSMenu.didBeginTrackingNotification, NSApplication.didBecomeActiveNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshMenu()
            })
        }
        let distributed = DistributedNotificationCenter.default()
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.sessionState"), object: nil, queue: .main) {
            [weak self] event in
            guard let pid = event.userInfo?["pid"] as? Int,
                  let active = event.userInfo?["active"] as? Bool else { return }
            self?.mirrorTarget.session(pid: pid, active: active)
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.receiverStatus"), object: nil, queue: .main) {
            [weak self] event in
            guard !NotificationRuntime.background, let self else { return }
            self.remoteMediaStatus = event.userInfo?["media"] as? String ?? self.remoteMediaStatus
            self.remoteClipboardStatus = event.userInfo?["clipboard"] as? String ?? self.remoteClipboardStatus
            self.remoteStatus = event.userInfo?["status"] as? String ?? self.remoteStatus
            self.remoteEndpoint = event.userInfo?["endpoint"] as? String ?? self.remoteEndpoint
            self.refreshMenu()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.receiverConfiguration"), object: nil, queue: .main) {
            [weak self] _ in
            guard NotificationRuntime.background, let self else { return }
            BLETrust.invalidate()
            self.media?.clear()
            self.media?.controller = nil
            self.hotspot?.controller = nil
            self.hotspot?.clear()
            self.taskContinuation?.clear()
            self.links.cancel()
            self.controller?.stop(); self.controller = nil; self.subscriptions.removeAll()
            if NotificationRuntime.preferences.bool(forKey: self.enabledKey) { self.start() }
            self.phoneNotifications?.controller = self.controller
            self.publishStatus()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.adbConfiguration"), object: nil, queue: .main) {
            [weak self] _ in
            NotificationRuntime.preferences.synchronize()
            self?.controller?.configureADB()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.clipboardConfiguration"), object: nil, queue: .main) {
            [weak self] _ in
            guard NotificationRuntime.background else { return }
            self?.clipboard?.configure()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.hotspotConfiguration"), object: nil, queue: .main) {
            [weak self] _ in
            guard NotificationRuntime.background else { return }
            self?.hotspot?.configure()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.mediaConfiguration"), object: nil, queue: .main) {
            [weak self] _ in self?.media?.configure()
        })
        refreshMenu()
    }

    private func publishStatus() {
        NotificationRuntime.post("app.droidmirror.receiverStatus", info: [
            "status": controller?.status ?? "Bluetooth receiver disabled",
            "bleDiagnostics": controller?.diagnostics ?? "disabled",
            "notifications": phoneNotifications?.diagnostics ?? "unavailable",
            "media": media?.status ?? "Media syncing off",
            "clipboard": clipboard?.status ?? "Clipboard mirroring off",
            "endpoint": controller?.adbStatus ?? "Wireless ADB off"])
    }

    private func start() {
        let bridge = BLEController()
        controller = bridge
        links.controller = bridge
        phoneNotifications?.controller = bridge
        media?.controller = bridge
        clipboard?.controller = bridge
        taskContinuation?.controller = bridge
        hotspot?.controller = bridge
        bridge.onEvent = { [weak self] event in
            if ["shareLink", "openLinkResult"].contains(event["type"] as? String ?? "") {
                self?.links.receive(event)
            } else if (event["type"] as? String)?.hasPrefix("media") == true {
                self?.media?.receive(event)
            } else if event["type"] as? String == "hotspotResult" {
                self?.hotspot?.receive(event)
            } else if event["type"] as? String == "taskContinuation" {
                self?.taskContinuation?.receive(event)
            } else if (event["type"] as? String)?.hasPrefix("clipboard") == true {
                self?.clipboard?.receive(event)
            } else if event["type"] as? String == "minimizeMirror" {
                guard let pid = self?.mirrorTarget.target() else {
                    NSLog("DroidMirror minimize: no active mirror heartbeat")
                    return
                }
                NSLog("DroidMirror minimize: forwarding to host %d", pid)
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("app.droidmirror.minimizeMirror"),
                    object: String(pid), userInfo: nil, deliverImmediately: true)
            } else {
                self?.phoneNotifications?.receive(event)
            }
        }
        bridge.onDisconnected = { [weak self] in
            self?.media?.clear()
            self?.clipboard?.disconnected()
            self?.taskContinuation?.clear()
            self?.hotspot?.clear()
            self?.links.disconnected()
        }
        bridge.onAuthenticated = { [weak self] in
            self?.phoneNotifications?.flush()
            self?.media?.connected()
            self?.clipboard?.connected()
            self?.taskContinuation?.connected()
            self?.links.connected()
            self?.hotspot?.configure()
        }
        bridge.$status.sink { status in
            NSLog("DroidMirror BLE: %@", status)
        }.store(in: &subscriptions)
    }

    func stop() {
        stopped = true
        links.cancel()
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        menuObservers.removeAll()
        media?.stop()
        clipboard?.stop()
        taskContinuation?.stop()
        hotspot?.stop()
        phoneNotifications?.stop()
        discoveryNotifications?.stop()
        timer?.invalidate()
        controller?.stop()
        controller = nil
        subscriptions.removeAll()
    }

    private func installMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let menuItem { BLEMenuAttachment.ensure(menuItem, in: menu); return }
        let root = NSMenuItem(title: "Background Bluetooth", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: root.title)
        let toggle = NSMenuItem(title: "Keep phone connected over Bluetooth", action: #selector(toggleBLE(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = NotificationRuntime.preferences.bool(forKey: enabledKey) ? .on : .off
        sub.addItem(toggle)
        let adb = NSMenuItem(title: "Automatically connect Wireless ADB", action: #selector(toggleADB(_:)), keyEquivalent: "")
        adb.target = self
        sub.addItem(adb)
        adbItem = adb
        let configure = NSMenuItem(title: "Set phone IP address…", action: #selector(configureHost(_:)), keyEquivalent: "")
        configure.target = self
        sub.addItem(configure)
        sub.addItem(.separator())
        let clipboardToggle = NSMenuItem(title: "Mirror clipboard over Bluetooth", action: #selector(toggleClipboard(_:)), keyEquivalent: "")
        clipboardToggle.target = self
        sub.addItem(clipboardToggle)
        clipboardItem = clipboardToggle
        let clipboardStatus = NSMenuItem(title: remoteClipboardStatus, action: nil, keyEquivalent: "")
        sub.addItem(clipboardStatus)
        clipboardStatusItem = clipboardStatus
        sub.addItem(.separator())
        let mediaToggle = NSMenuItem(title: "Sync phone and Apple Music playback", action: #selector(toggleMedia(_:)), keyEquivalent: "")
        mediaToggle.target = self
        sub.addItem(mediaToggle)
        mediaItem = mediaToggle
        let mediaStatus = NSMenuItem(title: remoteMediaStatus, action: nil, keyEquivalent: "")
        sub.addItem(mediaStatus)
        mediaStatusItem = mediaStatus
        sub.addItem(.separator())
        let status = NSMenuItem(title: "Starting Bluetooth…", action: nil, keyEquivalent: "")
        let endpoint = NSMenuItem(title: "Wireless ADB off", action: nil, keyEquivalent: "")
        sub.addItem(status)
        sub.addItem(endpoint)
        root.submenu = sub
        menuItem = root
        statusItem = status
        endpointItem = endpoint
        BLEMenuAttachment.ensure(root, in: menu)
    }

    func refreshMenu() {
        guard !NotificationRuntime.background, !stopped, !repairingMenu else { return }
        repairingMenu = true
        defer { repairingMenu = false }
        installMenu()
        updateMenu()
    }

    private func updateMenu() {
        adbItem?.state = NotificationRuntime.preferences.bool(forKey: BLEController.automaticADBKey) ? .on : .off
        mediaItem?.state = NotificationRuntime.preferences.bool(forKey: MediaPlaybackSync.enabledKey) ? .on : .off
        mediaStatusItem?.title = remoteMediaStatus
        clipboardItem?.state = NotificationRuntime.preferences.bool(forKey: ClipboardSync.enabledKey) ? .on : .off
        clipboardStatusItem?.title = remoteClipboardStatus
        menuItem?.submenu?.items.first?.state = NotificationRuntime.preferences.bool(forKey: enabledKey) ? .on : .off
        statusItem?.title = NotificationRuntime.background ? (controller?.status ?? "Bluetooth discovery disabled") : remoteStatus
        if !NotificationRuntime.background { endpointItem?.title = remoteEndpoint; return }
        endpointItem?.title = controller?.adbStatus ?? "Wireless ADB off"
    }

    @objc private func toggleBLE(_ sender: NSMenuItem) {
        let enabled = !NotificationRuntime.preferences.bool(forKey: enabledKey)
        NotificationRuntime.preferences.set(enabled, forKey: enabledKey)
        NotificationRuntime.preferences.synchronize()
        sender.state = enabled ? .on : .off
        if !NotificationRuntime.background {
            NotificationRuntime.post("app.droidmirror.receiverConfiguration"); updateMenu(); return
        }
        if enabled {
            start()
        } else {
            links.cancel()
            media?.clear()
            taskContinuation?.clear()
            controller?.stop()
            controller = nil
            subscriptions.removeAll()
        }
        updateMenu()
    }

    @objc private func toggleMedia(_ sender: NSMenuItem) {
        let enabled = !NotificationRuntime.preferences.bool(forKey: MediaPlaybackSync.enabledKey)
        NotificationRuntime.preferences.set(enabled, forKey: MediaPlaybackSync.enabledKey)
        NotificationRuntime.preferences.synchronize()
        NotificationRuntime.post("app.droidmirror.mediaConfiguration")
        updateMenu()
    }

    @objc private func toggleADB(_ sender: NSMenuItem) {
        let enabled = !NotificationRuntime.preferences.bool(forKey: BLEController.automaticADBKey)
        NotificationRuntime.preferences.set(enabled, forKey: BLEController.automaticADBKey)
        NotificationRuntime.preferences.synchronize()
        NotificationRuntime.post("app.droidmirror.adbConfiguration")
        updateMenu()
    }

    @objc private func toggleClipboard(_ sender: NSMenuItem) {
        let enabled = !NotificationRuntime.preferences.bool(forKey: ClipboardSync.enabledKey)
        NotificationRuntime.preferences.set(enabled, forKey: ClipboardSync.enabledKey)
        NotificationRuntime.preferences.synchronize()
        sender.state = enabled ? .on : .off
        NotificationRuntime.post("app.droidmirror.clipboardConfiguration")
    }

    @objc private func configureHost(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Wireless ADB phone address"
        alert.informativeText = "Enter the phone's Tailscale IP or hostname, without a port. Leave blank to learn the address from Android. ADB must already be paired."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = controller?.tailscaleIP ?? NotificationRuntime.preferences.string(forKey: "DroidMirror.BLE.host") ?? ""
        field.placeholderString = "100.x.x.x"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Endpoint construction uses arguments, never a shell. Reject accidental ports.
        guard host.isEmpty || host.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            NSSound.beep()
            return
        }
        NotificationRuntime.preferences.set(host, forKey: "DroidMirror.BLE.host")
        NotificationRuntime.preferences.synchronize()
        NotificationRuntime.post("app.droidmirror.adbConfiguration")
    }

}
