import AppKit

final class BLEController {
    var authenticated = true
    var supportsHotspot = true
    var sent = [[String: Any]]()
    var sendSucceeds = true
    @discardableResult func send(_ event: [String: Any]) -> Bool { sent.append(event); return sendSucceeds }
}
enum NotificationRuntime {
    static let preferences = UserDefaults(suiteName: "app.droidmirror.hotspot.tests.\(UUID())")!
}

@main struct PhoneHotspotTests {
    static func main() {
        var policy = HotspotPolicy()
        precondition(!policy.shouldStart(enabled: true, ready: true, now: 100)) // No initial path yet.
        policy.observe(offline: true, now: 100)
        precondition(!policy.shouldStart(enabled: true, ready: true, now: 114))
        precondition(!policy.shouldStart(enabled: false, ready: true, now: 115))
        precondition(!policy.shouldStart(enabled: true, ready: false, now: 115))
        precondition(policy.shouldStart(enabled: true, ready: true, now: 115))
        policy.didAttempt(now: 115)
        precondition(!policy.shouldStart(enabled: true, ready: true, now: 1000)) // Never retry this outage.
        policy.observe(offline: false, now: 120)
        policy.observe(offline: true, now: 125)
        precondition(!policy.shouldStart(enabled: true, ready: true, now: 140)) // Flap cooldown.
        precondition(policy.shouldStart(enabled: true, ready: true, now: 415))
        policy.observe(offline: false, now: 416)
        precondition(!policy.shouldStart(enabled: true, ready: true, now: 1000))

        _ = NSApplication.shared
        let phone = BLEController()
        var ssid: String? = "Home"
        var wifiConnected = true
        let hotspot = PhoneHotspot(monitorNetwork: false, requestLocationPermission: false,
            readSSID: { ssid }, readWiFiConnected: { wifiConnected })
        hotspot.controller = phone
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == false) // Other Wi-Fi, even before any hotspot use.
        hotspot.networkChanged(offline: true)
        precondition(hotspot.item?.isVisible == false) // A Wi-Fi network without Internet stays hidden.
        ssid = nil
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == false) // Redacted SSID is not disconnected Wi-Fi.
        wifiConnected = false
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == true) // No Wi-Fi, even with an Ethernet Internet route.
        precondition(hotspot.item?.menu == nil)
        precondition(hotspot.item?.button?.image != nil)
        precondition(hotspot.item?.button?.accessibilityLabel() == "DroidMirror phone hotspot")
        precondition(hotspot.item?.button?.image?.isTemplate == true)
        precondition(phone.sent.isEmpty)
        func click() { hotspot.item!.button!.performClick(nil) }
        func summary() -> String { hotspot.item!.button!.toolTip! }
        func reply(_ status: String, ssid: String? = nil) {
            var event: [String: Any] = ["type": "hotspotResult", "request": phone.sent.last!["request"]!, "status": status]
            event["ssid"] = ssid
            hotspot.receive(event)
        }
        click()
        precondition(phone.sent.count == 1 && phone.sent[0]["type"] as? String == "hotspotStart")
        precondition(!hotspot.item!.button!.isEnabled)
        click()
        precondition(phone.sent.count == 1) // No overlapping requests.
        hotspot.receive(["type": "hotspotResult", "request": "old-request", "status": "started"])
        precondition(summary() == "Turning on phone hotspot…")
        phone.authenticated = false
        reply("started")
        precondition(summary() == "Turning on phone hotspot…")
        phone.authenticated = true
        reply("started", ssid: "Phone")
        precondition(hotspot.isOn && hotspot.item!.button!.image!.isTemplate == false)
        precondition(hotspot.item!.length == 48)
        precondition(hotspot.item!.button!.image!.size == NSSize(width: 40, height: 22))
        precondition(phone.sent.count == 1)
        ssid = "Home"; wifiConnected = true
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == false) // Hotspot being on does not force visibility.
        precondition(phone.sent.count == 1) // Waiting to join is not departure.
        ssid = "Phone"
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == true && phone.sent.count == 1)
        ssid = nil
        hotspot.networkChanged(offline: true)
        precondition(phone.sent.count == 1) // Disconnects/redacted SSIDs are not network switches.
        ssid = "Cafe"
        hotspot.networkChanged(offline: false)
        precondition(phone.sent.count == 2 && phone.sent.last!["type"] as? String == "hotspotStop")
        precondition(hotspot.isOn) // Remain green until stop is confirmed.
        precondition(hotspot.item?.isVisible == false) // Hide on other Wi-Fi, even while stopping.
        reply("stopped")
        precondition(!hotspot.isOn && hotspot.item?.isVisible == false)
        precondition(hotspot.item!.button!.image!.isTemplate)
        precondition(hotspot.item!.length == NSStatusItem.squareLength)
        wifiConnected = false; ssid = nil
        hotspot.networkChanged(offline: true)
        precondition(hotspot.item?.isVisible == true)
        click(); reply("started", ssid: "Phone")
        ssid = "Phone"; wifiConnected = true
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item?.isVisible == true)
        click()
        precondition(phone.sent.last!["type"] as? String == "hotspotStop")
        reply("unavailable")
        precondition(hotspot.isOn) // A failed stop must not claim the phone is off.
        click(); reply("stopped")
        precondition(!hotspot.isOn && hotspot.item?.isVisible == true) // Still associated during shutdown.
        precondition(hotspot.item!.button!.image!.isTemplate)
        precondition(hotspot.item!.length == NSStatusItem.squareLength)
        wifiConnected = false; ssid = nil
        hotspot.networkChanged(offline: true)
        precondition(hotspot.item?.isVisible == true) // Off and disconnected stays available.
        click()
        hotspot.clear()
        reply("started", ssid: "Phone")
        precondition(!hotspot.isOn && summary().contains("connection changed"))
        phone.sendSucceeds = false
        click()
        precondition(summary().contains("Could not send"))
        phone.sendSucceeds = true
        click(); reply("started", ssid: "Phone")
        ssid = "Phone"; wifiConnected = true; hotspot.networkChanged(offline: false)
        phone.authenticated = false
        hotspot.clear()
        ssid = "Home"; hotspot.networkChanged(offline: false)
        let count = phone.sent.count
        phone.authenticated = true; hotspot.configure()
        precondition(phone.sent.count == count + 1 && phone.sent.last!["type"] as? String == "hotspotStop")
        reply("stopped")
        precondition(hotspot.item?.isVisible == false)
        wifiConnected = false; ssid = nil
        hotspot.networkChanged(offline: false)
        phone.supportsHotspot = false
        hotspot.configure()
        precondition(!hotspot.item!.button!.isEnabled)
        precondition(hotspot.item != nil)
        hotspot.stop()
        precondition(hotspot.item == nil)
        print("Phone hotspot toggle, Wi-Fi departure, conditional icon, authentication and request correlation tests passed")
    }
}
