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
        bridge.onEvent = { [weak self] event in self?.phoneNotifications?.receive(event) }
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
        let pair = NSMenuItem(title: "Pair phone using authorized ADB…", action: #selector(pairPhone(_:)), keyEquivalent: "")
        pair.target = self; sub.addItem(pair)
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

    @objc private func pairPhone(_ sender: Any?) {
        guard let adb = BLEController.findADB() else { return }
        let alert = NSAlert()
        alert.messageText = "Pair encrypted Bluetooth"
        alert.informativeText = "On your phone, open BLE ADB Bridge and tap Allow Mac pairing for 60 seconds. This uses an already-authorized ADB connection to provision a private key."
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = adb; task.arguments = ["devices"]
            let result = (try? BLEController.runBounded(task, timeout: 8)) ?? ""
            let devices = result.split(separator: "\n").compactMap { line -> String? in
                let columns = line.split(whereSeparator: { $0.isWhitespace })
                return columns.count == 2 && columns[1] == "device" ? String(columns[0]) : nil
            }
            DispatchQueue.main.async {
                guard !devices.isEmpty else { self.pairResult(false); return }
                var serial = devices[0]
                if devices.count > 1 {
                    let choice = NSAlert(); choice.messageText = "Choose the phone to pair"
                    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 26))
                    popup.addItems(withTitles: devices); choice.accessoryView = popup
                    choice.addButton(withTitle: "Pair"); choice.addButton(withTitle: "Cancel")
                    guard choice.runModal() == .alertFirstButtonReturn else { return }
                    serial = popup.titleOfSelectedItem ?? serial
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    var success = false
                    do {
                        let key = try BLETrust.random()
                        let task = Process(); task.executableURL = adb; task.arguments = ["-s", serial, "shell", "sh"]
                        // Key is supplied through stdin, never process arguments or logs.
                        let command = "content call --uri content://dev.bleadb.bridge.pairing --method pair --arg '\(key.base64EncodedString())'\n"
                        let output = try BLEController.runBounded(task, timeout: 10, input: Data(command.utf8))
                        if output.contains("status=paired-v2") { try BLETrust.save(key); success = true }
                    } catch { /* No key or remote command output is logged. */ }
                    DispatchQueue.main.async { self.pairResult(success) }
                }
            }
        }
    }
    private func pairResult(_ success: Bool) {
        if success {
            NotificationRuntime.preferences.set(true, forKey: enabledKey)
            NotificationRuntime.preferences.synchronize()
            if NotificationRuntime.background { controller?.stop(); subscriptions.removeAll(); start() }
            else { NotificationRuntime.post("app.droidmirror.receiverConfiguration") }
        }
        let alert = NSAlert()
        alert.messageText = success ? "Encrypted Bluetooth paired" : "Pairing did not complete"
        alert.informativeText = success ? "Enable DroidMirror notification forwarding in Android's notification access settings." :
            "Install BLE ADB Bridge 2.0, authorize ADB, then open the phone's 60-second pairing window and try again."
        alert.runModal()
    }
}
