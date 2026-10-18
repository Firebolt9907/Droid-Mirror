import Foundation

@main struct BLESessionTests {
    static func main() throws {
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
        precondition(queue.append(["type": "openLink"], deadline: 10))
        precondition(queue.next(now: 10) == nil && queue.bytes == 0)
        precondition(!queue.append(["data": String(repeating: "x", count: 5801)], deadline: 20))
        var accepted = 0
        while queue.append(["data": String(repeating: "x", count: 4096)], deadline: 30) { accepted += 1 }
        precondition(accepted > 0 && queue.bytes <= BLEOutboundQueue.limit)
        queue.reset()
        precondition(queue.count == 0 && queue.bytes == 0)
        print("PASS: duplicate service recovery, request correlation, deadlines, reset, bounded queues, control latency and bulk fairness")
    }
}
