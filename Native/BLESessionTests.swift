import Foundation

@main struct BLESessionTests {
    static func main() throws {
        var subscription = BLENotificationSubscription()
        precondition(subscription.updated(notifying: true) == .none)
        precondition(subscription.begin(alreadyNotifying: true) == .disable)
        precondition(subscription.updated(notifying: true) == .none) // Late cached callback.
        precondition(subscription.updated(notifying: false) == .enable)
        precondition(subscription.updated(notifying: false) == .none) // Duplicate disable completion.
        precondition(subscription.updated(notifying: true) == .authenticate)
        for _ in 0..<10 { precondition(subscription.updated(notifying: true) == .none) }
        // A real loss of subscription requires a fresh handshake exactly once.
        precondition(subscription.updated(notifying: false) == .enable)
        precondition(subscription.updated(notifying: true) == .authenticate)
        precondition(subscription.begin(alreadyNotifying: false) == .enable)
        precondition(subscription.updated(notifying: true) == .authenticate)
        precondition(subscription.updated(notifying: true) == .none)

        final class Service { let uuid = "same-service" }
        let stale = Service(), live = Service()
        var candidates = BLEServiceCandidates<Service>()
        candidates.reset([stale, stale, live])
        precondition(candidates.next() === stale)
        // A cached duplicate UUID must still be tried after the stale handle
        // fails; repeated callbacks for the old object must not select it again.
        precondition(candidates.next() === live)
        precondition(candidates.current !== stale)
        precondition(candidates.next() == nil)
        precondition(candidates.next() == nil)
        candidates.reset([live]); precondition(candidates.next() === live)
        candidates.reset(); precondition(candidates.current == nil && candidates.next() == nil)

        let requests = BLERequests()
        var outcomes = [String]()
        func record(_ result: BLERequestOutcome) {
            switch result {
            case .response: outcomes.append("response")
            case .timedOut: outcomes.append("timeout")
            case .disconnected: outcomes.append("disconnect")
            case .notQueued: outcomes.append("rejected")
            }
        }
        precondition(requests.add(id: "a", reply: "pong", deadline: 20, completion: record))
        precondition(!requests.add(id: "a", reply: "pong", deadline: 20, completion: record))
        requests.receive(["type": "pong", "request": "old"], now: 10)
        requests.receive(["type": "wrong", "request": "a"], now: 10)
        precondition(outcomes.isEmpty)
        requests.receive(["type": "pong", "request": "a"], now: 11)
        requests.receive(["type": "pong", "request": "a"], now: 11)
        precondition(outcomes == ["response"])
        precondition(requests.add(id: "b", reply: "result", deadline: 20, completion: record))
        requests.receive(["type": "result", "request": "b"], now: 20)
        precondition(outcomes.last == "timeout")
        precondition(requests.add(id: "c", reply: "result", deadline: 20, completion: record))
        requests.expire(now: 21); requests.expire(now: 22)
        precondition(outcomes == ["response", "timeout", "timeout"])
        precondition(requests.add(id: "d", reply: "result", deadline: 40, completion: record))
        requests.reset(); requests.reset()
        requests.receive(["type": "result", "request": "d"], now: 23)
        precondition(outcomes.last == "disconnect" && requests.count == 0)

        var queue = BLEOutboundQueue()
        precondition(queue.append(["type": "clipboardFileChunk", "offset": 0], deadline: 60))
        precondition(queue.append(["type": "clipboardFileChunk", "offset": 1], deadline: 60))
        for i in 0..<8 { precondition(queue.append(["type": "mediaCommand", "i": i], deadline: 60)) }
        for i in 0..<4 { precondition(queue.next(now: 1)!.object["i"] as? Int == i) }
        precondition(queue.next(now: 1)!.object["offset"] as? Int == 0)
        for i in 4..<8 { precondition(queue.next(now: 1)!.object["i"] as? Int == i) }
        precondition(queue.next(now: 1)!.object["offset"] as? Int == 1)
        precondition(queue.bytes == 0)
        precondition(queue.append(["type": "mediaState", "i": 0], deadline: 60))
        precondition(queue.append(["type": "mediaState", "i": 1], deadline: 60))
        precondition(queue.append(["type": "ping"], deadline: 60))
        precondition(queue.next(now: 1)!.object["type"] as? String == "ping")
        precondition(queue.next(now: 1)!.object["i"] as? Int == 0)
        precondition(queue.next(now: 1)!.object["i"] as? Int == 1)
        precondition(queue.append(["type": "appIconRequest"], deadline: 60))
        precondition(queue.append(["type": "appCatalogRequest"], deadline: 60))
        precondition(queue.append(["type": "appLaunch"], deadline: 60))
        precondition(queue.next(now: 1)!.object["type"] as? String == "appLaunch")
        precondition(queue.next(now: 1)!.object["type"] as? String == "appIconRequest")
        precondition(queue.next(now: 1)!.object["type"] as? String == "appCatalogRequest")
        precondition(queue.append(["type": "openLink"], deadline: 10))
        precondition(queue.next(now: 10) == nil && queue.bytes == 0)
        precondition(!queue.append(["data": String(repeating: "x", count: 5801)], deadline: 20))
        var accepted = 0
        while queue.append(["data": String(repeating: "x", count: 4096)], deadline: 30) { accepted += 1 }
        precondition(accepted > 0 && queue.bytes <= BLEOutboundQueue.limit)
        // Expired bulk work must free all reservations before a reconnect/new
        // command; saturation must not leak capacity or poison FIFO ordering.
        precondition(queue.next(now: 30) == nil && queue.count == 0 && queue.bytes == 0)
        precondition(queue.append(["type": "mediaCommand", "i": 100], deadline: 40))
        precondition(queue.append(["type": "mediaCommand", "i": 101], deadline: 40))
        precondition(queue.next(now: 31)!.object["i"] as? Int == 100)
        precondition(queue.next(now: 31)!.object["i"] as? Int == 101)
        queue.reset()
        precondition(queue.count == 0 && queue.bytes == 0)
        print("PASS: duplicate service recovery, request correlation, deadlines, reset, bounded queues, control latency and bulk fairness")
    }
}
