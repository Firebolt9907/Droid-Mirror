import AppKit
import Network
import CoreWLAN
import CoreLocation

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
final class PhoneHotspot: NSObject {
    static let automaticKey = "DroidMirror.hotspot.automatic"
    weak var controller: BLEController?
    // Draw the active treatment inside the image so it remains inset from the
    // menu bar edges, rather than coloring the entire rectangular status button.
    private static let inactiveImage: NSImage? = {
        let image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: "Phone hotspot")
        image?.isTemplate = true
        return image
    }()
    private static let activeImage: NSImage = {
        let size = NSSize(width: 40, height: 22)
        let symbol = inactiveImage?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        symbol?.isTemplate = false
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.79, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            if let symbol {
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2,
                    width: symbolSize.width, height: symbolSize.height))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Phone hotspot on"
        return image
    }()
    private let monitor = NWPathMonitor()
    private let location = CLLocationManager()
    private let readSSID: () -> String?
    private let readWiFiConnected: () -> Bool
    private let requestLocationPermission: Bool
    private var timer: Timer?
    private(set) var item: NSStatusItem?
    private(set) var isOn = false
    private var hotspotSSID: String?
    private var joinedHotspot = false
    private var needsStop = false
    private var offline: Bool?
    private var policy = HotspotPolicy()
    private var pending: (id: String, enabled: Bool)?
    private var deadline: TimeInterval = 0
    private var message: String?
    private var messageUntil: TimeInterval = 0
    private var stopped = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var ready: Bool { controller?.authenticated == true && controller?.supportsHotspot == true }

    init(monitorNetwork: Bool = true, requestLocationPermission: Bool = true, readSSID: @escaping () -> String? = {
        CWWiFiClient.shared().interface()?.ssid()
    }, readWiFiConnected: @escaping () -> Bool = {
        // SSIDs can be redacted without Location access; that does not mean no Wi-Fi.
        CWWiFiClient.shared().interfaces()?.contains { $0.activePHYMode().rawValue != 0 } ?? false
    }) {
        self.readSSID = readSSID
        self.readWiFiConnected = readWiFiConnected
        self.requestLocationPermission = requestLocationPermission
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                // Route availability alone cannot identify the phone's hotspot.
                self.networkChanged(offline: path.status != .satisfied)
            }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "app.droidmirror.hotspot.network")) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
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
        if let pending {
            // A lost acknowledgement is ambiguous. Keep a stop intent across BLE reconnects.
            if !pending.enabled { needsStop = true }
            message = "Bluetooth connection changed. Check the phone before retrying."
            messageUntil = now + 60
        }
        pending = nil
        refresh()
    }

    func receive(_ event: [String: Any]) {
        guard controller?.authenticated == true, let pending,
              event["type"] as? String == "hotspotResult", event["request"] as? String == pending.id,
              let status = event["status"] as? String else { return }
        self.pending = nil
        switch status {
        case "started" where pending.enabled:
            isOn = true
            hotspotSSID = (event["ssid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            joinedHotspot = false
            message = "Phone hotspot is on. Join it from the Wi-Fi menu. Click to turn off."
        case "stopped" where !pending.enabled:
            isOn = false; joinedHotspot = false; needsStop = false
            message = "Phone hotspot is off. Click to turn on."
        case "shizuku": message = "Start and authorize Shizuku on your phone."
        case "busy": message = "Hotspot request already in progress. Check the phone."
        case "unsupported": message = "Update the companion; hotspot toggle needs Android 11 or newer."
        case "timeout": message = "No confirmation. Check the phone before retrying."
        default: message = "Android could not change tethering. Check hotspot settings on the phone."
        }
        // Errors are shown for a manual retry, never retried every timer tick.
        if !pending.enabled { needsStop = false }
        messageUntil = now + 60
        refresh()
    }

    private func refresh() {
        guard !stopped else { return }
        if let pending, !ready || now >= deadline {
            self.pending = nil
            if !pending.enabled && !ready { needsStop = true }
            message = "No confirmation. Check the phone before retrying."
            messageUntil = now + 60
        }
        if now >= messageUntil { message = nil }
        let wifiConnected = readWiFiConnected()
        let ssid = wifiConnected ? readSSID() : nil
        if isOn, let hotspotSSID, let ssid, !ssid.isEmpty {
            if ssid == hotspotSSID {
                joinedHotspot = true
            } else if joinedHotspot {
                joinedHotspot = false
                needsStop = true
            }
        }
        if needsStop && ready && pending == nil {
            needsStop = false
            setHotspot(enabled: false)
            return
        }
        if !isOn && offline == true && pending == nil && policy.shouldStart(
            enabled: NotificationRuntime.preferences.bool(forKey: Self.automaticKey), ready: ready, now: now) {
            setHotspot(enabled: true)
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(toggle)
            item.button?.setAccessibilityLabel("DroidMirror phone hotspot")
            self.item = item
        }
        // Visibility follows Wi-Fi association, independently of Internet routes,
        // pending commands, and tooltip messages. Retain the known phone SSID
        // after shutdown so the icon remains until Wi-Fi actually disconnects.
        item?.isVisible = !wifiConnected || (hotspotSSID != nil && ssid == hotspotSSID)
        let button = item?.button
        button?.isEnabled = ready && pending == nil
        item?.length = isOn ? 48 : NSStatusItem.squareLength
        button?.image = isOn ? Self.activeImage : Self.inactiveImage
        button?.setAccessibilityValue(isOn ? "On" : "Off")
        if let pending {
            button?.toolTip = pending.enabled ? "Turning on phone hotspot…" : "Turning off phone hotspot…"
        } else {
            button?.toolTip = message ?? (!ready ? "Waiting for a paired phone with hotspot toggle support…" :
                isOn ? (joinedHotspot ? "Connected to phone hotspot. Click to turn off." :
                    "Phone hotspot is on. Click to turn off.") : "Phone hotspot is off. Click to turn on.")
        }
    }

    private func setHotspot(enabled: Bool) {
        guard ready, pending == nil else { return }
        if requestLocationPermission && enabled && location.authorizationStatus == .notDetermined {
            // macOS protects Wi-Fi network names with Location Services permission.
            location.requestWhenInUseAuthorization()
        }
        let request = UUID().uuidString
        if enabled { policy.didAttempt(now: now) }
        pending = (request, enabled); deadline = now + 35; message = nil
        if controller?.send(["type": enabled ? "hotspotStart" : "hotspotStop", "request": request]) != true {
            pending = nil
            message = "Could not send over Bluetooth. Try again when the phone reconnects."
            messageUntil = now + 60
        }
        refresh()
    }

    @objc private func toggle() {
        guard ready, pending == nil else { return }
        setHotspot(enabled: !isOn)
    }

    func stop() {
        stopped = true; monitor.cancel(); timer?.invalidate(); timer = nil; pending = nil
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
}
