import AppKit
import Network

/// At most one automatic attempt per outage, with a cooldown across network flaps.
struct HotspotPolicy {
    private var offlineSince: TimeInterval?
    private var attempted = false
    private var lastAttempt: TimeInterval?
    mutating func observe(offline: Bool, now: TimeInterval) {
        if offline {
            if offlineSince == nil { offlineSince = now }
        } else {
            offlineSince = nil
            attempted = false
        }
    }
    func shouldStart(enabled: Bool, ready: Bool, now: TimeInterval) -> Bool {
        guard enabled, ready, !attempted, let offlineSince, now - offlineSince >= 15 else { return false }
        return lastAttempt.map { now - $0 >= 300 } ?? true
    }
    mutating func didAttempt(now: TimeInterval) { attempted = true; lastAttempt = now }
}

/// Owned by the background Bluetooth receiver, so only one status item exists.
final class PhoneHotspot: NSObject, NSMenuDelegate {
    static let automaticKey = "DroidMirror.hotspot.automatic"
    weak var controller: BLEController?
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private(set) var item: NSStatusItem?
    private var offline: Bool?
    private var policy = HotspotPolicy()
    private var pending: String?
    private var deadline: TimeInterval = 0
    private var message: String?
    private var messageUntil: TimeInterval = 0
    private var stopped = false
    private var menuTracking = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var ready: Bool { controller?.authenticated == true && controller?.supportsHotspot == true }

    init(monitorNetwork: Bool = true) {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                // This means no usable network route, not a failed HTTP probe or captive portal.
                self.networkChanged(offline: path.status != .satisfied)
            }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "app.droidmirror.hotspot.network")) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func networkChanged(offline: Bool) {
        self.offline = offline
        policy.observe(offline: offline, now: now)
        refresh()
    }

    func configure() {
        NotificationRuntime.preferences.synchronize()
        refresh()
    }

    func clear() {
        if pending != nil { message = "Bluetooth connection changed. Check the phone before retrying."; messageUntil = now + 60 }
        pending = nil
        refresh()
    }

    func receive(_ event: [String: Any]) {
        guard controller?.authenticated == true, let pending,
              event["type"] as? String == "hotspotResult", event["request"] as? String == pending,
              let status = event["status"] as? String else { return }
        self.pending = nil
        switch status {
        case "started": message = "Phone hotspot is on. Join it from the Wi-Fi menu."
        case "shizuku": message = "Start and authorize Shizuku on your phone."
        case "busy": message = "Hotspot request already in progress. Check the phone."
        case "unsupported": message = "Hotspot control needs Android 11 or newer."
        case "timeout": message = "No confirmation. Check the phone before retrying."
        default: message = "Android could not enable tethering. Check hotspot settings on the phone."
        }
        messageUntil = now + 60
        refresh()
    }

    private func refresh() {
        guard !stopped else { return }
        if pending != nil && (!ready || now >= deadline) {
            pending = nil
            message = "No confirmation. Check the phone before retrying."
            messageUntil = now + 60
        }
        if now >= messageUntil { message = nil }
        if offline == true && pending == nil && policy.shouldStart(
            enabled: NotificationRuntime.preferences.bool(forKey: Self.automaticKey), ready: ready, now: now) {
            startHotspot()
            return
        }
        guard offline == true || pending != nil || message != nil else {
            removeItem(); return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: "Phone hotspot")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.setAccessibilityLabel("DroidMirror phone hotspot")
            self.item = item
        }
        item?.button?.toolTip = pending != nil ? "Turning on phone hotspot…" : "DroidMirror phone hotspot"
        // Avoid replacing a menu while the user is choosing a command.
        if menuTracking { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let summary = pending != nil ? "Turning on phone hotspot…" : message ?? (ready
            ? "Mac is offline. Use your phone’s hotspot."
            : "Waiting for a paired phone over Bluetooth…")
        let status = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if controller?.authenticated == true && controller?.supportsHotspot != true {
            let update = NSMenuItem(title: "Update the companion; Android 11+ required", action: nil, keyEquivalent: "")
            update.isEnabled = false; menu.addItem(update)
        }
        let start = NSMenuItem(title: "Turn On Phone Hotspot", action: #selector(turnOn), keyEquivalent: "")
        start.target = self; start.isEnabled = ready && pending == nil
        menu.addItem(start)
        let wifi = NSMenuItem(title: "Open Wi-Fi Settings…", action: #selector(openWiFi), keyEquivalent: "")
        wifi.target = self; menu.addItem(wifi)
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: "Automatically Turn On When Mac Is Offline", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self
        automatic.state = NotificationRuntime.preferences.bool(forKey: Self.automaticKey) ? .on : .off
        menu.addItem(automatic)
        let note = NSMenuItem(title: "Uses mobile data. Join the hotspot in Wi-Fi.", action: nil, keyEquivalent: "")
        note.isEnabled = false; menu.addItem(note)
        item?.menu = menu
    }

    private func startHotspot() {
        guard ready, pending == nil else { return }
        let request = UUID().uuidString
        policy.didAttempt(now: now)
        pending = request; deadline = now + 35; message = nil
        if controller?.send(["type": "hotspotStart", "request": request]) != true {
            pending = nil; message = "Could not send over Bluetooth. Try again when the phone reconnects."
            messageUntil = now + 60
        }
        refresh()
    }
    @objc private func turnOn() { startHotspot() }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    @objc private func toggleAutomatic() {
        let preferences = NotificationRuntime.preferences
        preferences.set(!preferences.bool(forKey: Self.automaticKey), forKey: Self.automaticKey)
        preferences.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.droidmirror.hotspotConfiguration"), object: nil, userInfo: nil, deliverImmediately: true)
        refresh()
    }
    @objc private func openWiFi() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(url) }
    }
    private func removeItem() {
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
    func stop() {
        stopped = true; monitor.cancel(); timer?.invalidate(); timer = nil; pending = nil; removeItem()
    }
}
