import AppKit
import IOKit.ps

/// Owned by the background Bluetooth receiver; the watch never gets Mac pairing credentials.
final class WearCompanion: NSObject {
    weak var controller: BLEController?
    private var gate = WearCompanionCommandGate()
    private var lastSent = -Double.infinity
    private var phoneAt = -Double.infinity
    private var phoneLevel = -1
    private var phoneCharging = false
    private var sound: NSSound?
    private var panel: NSPanel?
    private var soundTimeout: Timer?
    private var lastRing = -Double.infinity
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var batteryStatus: String {
        guard controller?.authenticated == true, uptime - phoneAt < 35 else { return "Phone battery unavailable" }
        return phoneLevel >= 0 ? "Phone battery: \(phoneLevel)%\(phoneCharging ? " · charging" : "")" : "Phone battery unavailable"
    }
    func connected() { clear(); tick() }
    func clear() {
        gate.reset(); lastSent = -Double.infinity; phoneAt = -Double.infinity
        phoneLevel = -1; stopSound()
    }
    func tick() {
        guard controller?.authenticated == true, controller?.supportsWearCompanion == true,
              uptime - lastSent >= 10 else { return }
        var event = Self.battery()
        event["type"] = "watchMacState"; event["id"] = gate.id
        event["ticket"] = gate.ticket(now: uptime)
        event["name"] = Host.current().localizedName ?? "Mac"
        if controller?.sendCompanion(event) == true { lastSent = uptime }
    }
    func receive(_ event: [String: Any]) {
        guard controller?.authenticated == true, event["id"] as? String == gate.id else { return }
        switch event["type"] as? String {
        case "watchPhoneBattery":
            guard let level = event["level"] as? Int, (-1...100).contains(level),
                  let charging = event["charging"] as? Bool else { return }
            phoneLevel = level; phoneCharging = charging; phoneAt = uptime
        case "watchFindMac":
            guard gate.accept(event, now: uptime) else { return }
            var success = false
            if uptime - lastRing >= 5 {
                lastRing = uptime
                success = ring()
            }
            controller?.sendCompanion(["type": "watchFindResult", "id": gate.id,
                "request": event["request"] as? String ?? "", "success": success])
        default: break
        }
    }
    static func battery() -> [String: Any] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return ["level": -1, "charging": false]
        }
        for source in sources {
            guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = value[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = value[kIOPSMaxCapacityKey] as? Int, maximum > 0, current >= 0 else { continue }
            return ["level": min(100, Int(Double(current) * 100 / Double(maximum))),
                    "charging": (value[kIOPSIsChargingKey] as? Bool == true) ||
                        (current >= maximum && value[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)]
        }
        return ["level": -1, "charging": false]
    }
    private func ring() -> Bool {
        stopSound()
        guard let sound = NSSound(named: NSSound.Name("Glass")) else { return false }
        sound.loops = true
        guard sound.play() else { return false }
        self.sound = sound
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "DroidMirror · Find my Mac"; panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Your watch is finding this Mac.")
        label.frame = NSRect(x: 24, y: 78, width: 300, height: 24)
        panel.contentView?.addSubview(label)
        let stop = NSButton(title: "Stop sound", target: self, action: #selector(stopSound))
        stop.frame = NSRect(x: 100, y: 22, width: 140, height: 32)
        panel.contentView?.addSubview(stop)
        panel.level = .floating; panel.center(); panel.orderFrontRegardless(); self.panel = panel
        soundTimeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.stopSound() }
        return true
    }
    @objc private func stopSound() {
        soundTimeout?.invalidate(); soundTimeout = nil; sound?.stop(); sound = nil
        panel?.close(); panel = nil
    }
}
