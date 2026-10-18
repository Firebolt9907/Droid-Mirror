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
        let hotspot = PhoneHotspot(monitorNetwork: false)
        hotspot.controller = phone
        precondition(hotspot.item == nil)
        hotspot.networkChanged(offline: false)
        precondition(hotspot.item == nil)
        hotspot.networkChanged(offline: true)
        precondition(hotspot.item != nil)
        precondition(hotspot.item?.button?.image != nil)
        precondition(hotspot.item?.button?.accessibilityLabel() == "DroidMirror phone hotspot")
        precondition(phone.sent.isEmpty) // Automatic mode defaults off.
        func start() {
            let menu = hotspot.item!.menu!
            let index = menu.items.firstIndex { $0.title == "Turn On Phone Hotspot" }!
            menu.performActionForItem(at: index)
        }
        func summary() -> String { hotspot.item!.menu!.items[0].title }
        start()
        precondition(phone.sent.count == 1 && phone.sent[0]["type"] as? String == "hotspotStart")
        let request = phone.sent[0]["request"] as! String
        hotspot.receive(["type": "hotspotResult", "request": "old-request", "status": "started"])
        precondition(summary() == "Turning on phone hotspot…")
        phone.authenticated = false
        hotspot.receive(["type": "hotspotResult", "request": request, "status": "started"])
        precondition(summary() == "Turning on phone hotspot…") // Unauthenticated result ignored.
        phone.authenticated = true
        hotspot.receive(["type": "hotspotResult", "request": request, "status": "started"])
        precondition(summary().contains("hotspot is on"))
        start()
        hotspot.clear()
        hotspot.receive(["type": "hotspotResult", "request": phone.sent[1]["request"]!, "status": "started"])
        precondition(summary().contains("connection changed"))
        phone.supportsHotspot = false
        hotspot.networkChanged(offline: true)
        precondition(hotspot.item!.menu!.items.first { $0.title == "Turn On Phone Hotspot" }!.isEnabled == false)
        hotspot.stop()
        precondition(hotspot.item == nil)
        print("Phone hotspot policy, menu, authentication and request correlation tests passed")
    }
}
