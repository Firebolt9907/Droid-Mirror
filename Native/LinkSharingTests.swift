import AppKit

final class BLEController {
    var authenticated = true
    var supportsLinkSharing = true
    var sent = [[String: Any]]()
    let requests = BLERequests()
    @discardableResult func request(_ event: [String: Any], expecting: String, timeout: TimeInterval,
                                   id: String, completion: @escaping (BLERequestOutcome) -> Void) -> String? {
        guard authenticated else { completion(.notQueued); return nil }
        guard requests.add(id: id, reply: expecting, deadline: ProcessInfo.processInfo.systemUptime + timeout,
                           completion: completion) else { completion(.notQueued); return nil }
        var command = event; command["request"] = id
        send(command)
        return id
    }
    @discardableResult func send(_ event: [String: Any]) -> Bool {
        guard authenticated else { return false }
        sent.append(event); return true
    }
}
enum TaskContinuationState {
    static func browserURL(_ raw: String) -> URL? { BrowserURL.browserURL(raw) }
}
@main struct LinkSharingTests {
    static func main() {
        let controller = BLEController()
        let links = LinkSharing()
        links.controller = controller
        var opened = [URL]()
        var errors = [String]()
        links.openBrowser = { opened.append($0); return true }
        links.report = { errors.append($0) }
        let id = UUID().uuidString
        let event: [String: Any] = ["type": "shareLink", "request": id, "url": "https://example.com/path?q=1&b=2"]
        controller.authenticated = false
        links.receive(event)
        precondition(opened.isEmpty && controller.sent.isEmpty)
        controller.authenticated = true
        links.receive(event); links.receive(event)
        precondition(opened.count == 1 && controller.sent.count == 2)
        precondition(controller.sent.last?["success"] as? Bool == true)
        for url in ["file:///tmp/test", "javascript:alert(1)", "https://user:pass@example.com"] {
            links.receive(["type": "shareLink", "request": UUID().uuidString, "url": url])
        }
        precondition(opened.count == 1)
        links.share(URL(string: "droidmirror-share://open?url=https%3A%2F%2Fexample.com%2Fpath%3Fq%3D1%26b%3D2")!)
        precondition(controller.sent.last?["type"] as? String == "openLink")
        precondition(controller.sent.last?["url"] as? String == "https://example.com/path?q=1&b=2")
        let count = controller.sent.count
        links.tick(); links.connected()
        precondition(controller.sent.count == count + 1) // subscription only, no duplicate send
        controller.requests.receive(["type": "openLinkResult", "request": "bad", "success": true], now: ProcessInfo.processInfo.systemUptime)
        let request = controller.sent.first { $0["type"] as? String == "openLink" }!["request"] as! String
        controller.requests.receive(["type": "openLinkResult", "request": request, "success": false], now: ProcessInfo.processInfo.systemUptime)
        precondition(errors.count == 1)
        controller.supportsLinkSharing = false
        links.share(URL(string: "droidmirror-share://open?url=https%3A%2F%2Fexample.com")!)
        precondition(errors.count == 2)
        controller.supportsLinkSharing = true
        controller.authenticated = false
        var now = Date()
        links.now = { now }
        let before = controller.sent.count
        links.share(URL(string: "droidmirror-share://open?url=https%3A%2F%2Fexample.com")!)
        precondition(controller.sent.count == before)
        now = now.addingTimeInterval(16)
        links.tick()
        precondition(errors.count == 3)
        controller.authenticated = true
        links.connected()
        precondition(controller.sent.count == before + 1) // expired requests never open later
        // A command whose confirmation was lost must never run again on reconnect.
        links.share(URL(string: "droidmirror-share://open?url=https%3A%2F%2Fexample.com")!)
        let sentBeforeReset = controller.sent.count
        controller.authenticated = false
        controller.requests.reset()
        links.disconnected()
        precondition(errors.count == 4)
        controller.authenticated = true
        links.connected()
        precondition(controller.sent.count == sentBeforeReset + 1) // subscription only
        print("PASS: authenticated sharing, browser dispatch, acknowledgments, deduplication, capability checks and URL safety")
    }
}
