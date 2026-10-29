import Foundation

// No Bluetooth or sound side effects: compile the real companion against this transport double.
final class BLEController {
    var supportsChangePush = false
    var authenticated = true
    var supportsWearCompanion = true
    var sent = [[String: Any]]()
    @discardableResult func sendCompanion(_ event: [String: Any]) -> Bool { sent.append(event); return true }
}

@main struct WearCompanionTests {
    static func main() {
        var gate = WearCompanionCommandGate()
        let id = gate.id
        let ticket = gate.ticket(now: 100)
        let request = UUID().uuidString
        let event: [String: Any] = ["id": id, "ticket": ticket, "request": request]
        assert(gate.accept(event, now: 101))
        assert(!gate.accept(event, now: 102), "duplicate must not ring twice")
        var wrong = event; wrong["request"] = UUID().uuidString; wrong["id"] = UUID().uuidString
        assert(!gate.accept(wrong, now: 102), "wrong connection")
        wrong["id"] = id; wrong["ticket"] = "missing"
        assert(!gate.accept(wrong, now: 102), "unadvertised ticket")
        wrong["ticket"] = ticket
        assert(!gate.accept(wrong, now: 99), "future ticket")
        assert(!gate.accept(wrong, now: 135), "expired ticket")
        gate.reset()
        assert(!gate.accept(event, now: 103), "old connection cannot ring after reauthentication")

        let transport = BLEController()
        let companion = WearCompanion(); companion.controller = transport; companion.connected()
        assert(transport.sent.count == 1)
        let state = transport.sent[0]
        assert(state["type"] as? String == "watchMacState")
        assert(UUID(uuidString: state["ticket"] as! String) != nil)
        let level = state["level"] as! Int
        assert((-1...100).contains(level)); assert(state["charging"] is Bool)
        companion.tick(); assert(transport.sent.count == 1, "battery heartbeats are bounded")
        companion.receive(["type": "watchPhoneBattery", "id": state["id"]!, "level": 73, "charging": true])
        assert(companion.batteryStatus == "Phone battery: 73% · charging")
        companion.receive(["type": "watchPhoneBattery", "id": state["id"]!, "level": 500, "charging": false])
        assert(companion.batteryStatus == "Phone battery: 73% · charging", "reject invalid battery")
        companion.clear(); assert(companion.batteryStatus == "Phone battery unavailable")
        companion.receive(["type": "watchPhoneBattery", "id": state["id"]!, "level": 20, "charging": false])
        assert(companion.batteryStatus == "Phone battery unavailable", "reject old connection battery")
        let push = BLEController(); push.supportsChangePush = true
        var now = 100.0, battery = 73
        let quiet = WearCompanion(clock: { now }, readBattery: { ["level": battery, "charging": false] })
        quiet.controller = push; quiet.connected()
        let pushID = push.sent[0]["id"]!
        for _ in 0..<100 { now += 10; quiet.tick() }
        assert(push.sent.count == 1, "Unchanged state must stay silent after legacy lease expiry")
        battery = 72; quiet.tick(); assert(push.sent.count == 2)
        quiet.receive(["type": "watchPhoneBattery", "id": pushID, "level": 30, "charging": false, "changeOnly": true])
        now += 100; assert(quiet.batteryStatus == "Phone battery: 30%")
        let ticketRequest = UUID().uuidString
        quiet.receive(["type": "watchTicketRequest", "id": pushID, "request": ticketRequest])
        assert(push.sent.last?["type"] as? String == "watchMacTicket")
        assert(push.sent.last?["request"] as? String == ticketRequest)
        quiet.clear()
        assert(quiet.batteryStatus == "Phone battery unavailable")
        quiet.receive(["type": "watchTicketRequest", "id": pushID, "request": UUID().uuidString])
        assert(push.sent.count == 3, "Old connections cannot acquire fresh command tickets")
        print("Wear companion: command expiry, replay, reconnection and battery tests passed")
    }
}
