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

private final class BLEIntegration: NSObject {
    private var mirrorTarget = MirrorWindowCommandTarget()
    private var controller: BLEController?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var menuItem: NSMenuItem?
    private var statusItem: NSMenuItem?
    private var endpointItem: NSMenuItem?
    private let enabledKey = "DroidMirror.BLE.enabled"
    private var discoveryNotifications: DiscoveryNotifications?
    private var phoneNotifications: AndroidNotificationBridge?
    private var menuObservers = [NSObjectProtocol]()
    private var repairingMenu = false
    private var stopped = false
    private var remoteStatus = "Starting background receiver…"
    private var remoteEndpoint = "Waiting for Android endpoint"

    override init() {
        super.init()
        discoveryNotifications = DiscoveryNotifications(warningsEnabled: !NotificationRuntime.background)
        phoneNotifications = NotificationRuntime.background ? AndroidNotificationBridge() : nil
        discoveryNotifications?.onResponse = { [weak self] response in self?.phoneNotifications?.respond(response) }
        NotificationRuntime.preferences.register(defaults: [enabledKey: true])
        if NotificationRuntime.background && NotificationRuntime.preferences.bool(forKey: enabledKey) { start() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NotificationRuntime.background { self.publishStatus() }
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
            self.remoteStatus = event.userInfo?["status"] as? String ?? self.remoteStatus
            self.remoteEndpoint = event.userInfo?["endpoint"] as? String ?? self.remoteEndpoint
            self.refreshMenu()
        })
        menuObservers.append(distributed.addObserver(forName: Notification.Name("app.droidmirror.receiverConfiguration"), object: nil, queue: .main) {
            [weak self] _ in
            guard NotificationRuntime.background, let self else { return }
            BLETrust.invalidate()
            self.controller?.stop(); self.controller = nil; self.subscriptions.removeAll()
            if NotificationRuntime.preferences.bool(forKey: self.enabledKey) { self.start() }
            self.phoneNotifications?.controller = self.controller
            self.publishStatus()
        })
        refreshMenu()
    }

    private func publishStatus() {
        NotificationRuntime.post("app.droidmirror.receiverStatus", info: [
            "status": controller?.status ?? "Bluetooth receiver disabled",
            "notifications": phoneNotifications?.diagnostics ?? "unavailable",
            "endpoint": controller.flatMap { bridge in bridge.port.map { "\(bridge.tailscaleIP):\($0)" } } ?? "Waiting for Android endpoint"])
    }

    private func start() {
        let bridge = BLEController()
        controller = bridge
        phoneNotifications?.controller = bridge
        bridge.onEvent = { [weak self] event in
            if event["type"] as? String == "minimizeMirror" {
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
        bridge.onAuthenticated = { [weak self] in self?.phoneNotifications?.flush() }
        bridge.$status.sink { status in
            NSLog("DroidMirror BLE: %@", status)
        }.store(in: &subscriptions)
    }

    func stop() {
        stopped = true
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        menuObservers.removeAll()
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
        let root = NSMenuItem(title: "Wireless ADB over Bluetooth", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: root.title)
        let toggle = NSMenuItem(title: "Automatically discover ADB port", action: #selector(toggleBLE(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = NotificationRuntime.preferences.bool(forKey: enabledKey) ? .on : .off
        sub.addItem(toggle)
        let configure = NSMenuItem(title: "Set phone IP address…", action: #selector(configureHost(_:)), keyEquivalent: "")
        configure.target = self
        sub.addItem(configure)
        sub.addItem(.separator())
        let status = NSMenuItem(title: "Starting Bluetooth…", action: nil, keyEquivalent: "")
        let endpoint = NSMenuItem(title: "Waiting for endpoint", action: nil, keyEquivalent: "")
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
        menuItem?.submenu?.items.first?.state = NotificationRuntime.preferences.bool(forKey: enabledKey) ? .on : .off
        statusItem?.title = NotificationRuntime.background ? (controller?.status ?? "Bluetooth discovery disabled") : remoteStatus
        if !NotificationRuntime.background { endpointItem?.title = remoteEndpoint; return }
        if let bridge = controller, let port = bridge.port {
            endpointItem?.title = "\(bridge.tailscaleIP):\(port)"
        } else {
            endpointItem?.title = "Waiting for Android endpoint"
        }
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
            controller?.stop()
            controller = nil
            subscriptions.removeAll()
        }
        updateMenu()
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
        if !NotificationRuntime.background { NotificationRuntime.post("app.droidmirror.receiverConfiguration"); return }
        controller?.tailscaleIP = host
        controller?.requestEndpoint()
        controller?.connectADB(force: true)
    }

}
