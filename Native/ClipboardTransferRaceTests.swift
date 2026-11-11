import Foundation
import CryptoKit

@main struct ClipboardTransferRaceTests {
    static func main() {
        let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        for scenario in 0..<3 {
            let winningLane = scenario == 0 ? 0 : 1
            let sender = ClipboardTransferRace(), receiver = ClipboardTransferRace()
            let id = UUID().uuidString
            var queues = [[[String: Any]]](repeating: [], count: 2)
            var delivered = Data(), applies = 0, wins = [Int]()
            var brokenIroh = false
            sender.wire = { lane, event in
                if lane == 1 && brokenIroh { return false }
                queues[lane].append(event); return true
            }
            receiver.wire = { lane, event in sender.receive(event, lane: lane); return true }
            receiver.won = { wins.append($0) }
            receiver.deliver = { event in
                switch event["type"] as? String {
                case "clipboardFileBegin":
                    precondition(event["destination"] as? String == "downloads")
                    _ = receiver.send(["type": "clipboardFileAck", "id": id, "offset": 0, "window": 32])
                case "clipboardFileChunk":
                    precondition(event["offset"] as? Int == delivered.count)
                    delivered.append(Data(base64Encoded: event["data"] as! String)!)
                    if delivered.count == bytes.count {
                        applies += 1
                        _ = receiver.send(["type": "clipboardFileAck", "id": id, "offset": bytes.count])
                    }
                default: break
                }
            }
            var offset = 0
            sender.deliver = { event in
                guard event["type"] as? String == "clipboardFileAck" else { return }
                for _ in 0..<32 where offset < bytes.count {
                    let end = min(bytes.count, offset + 3072)
                    let chunk: [String: Any] = ["type": "clipboardFileChunk", "id": id, "offset": offset, "data": bytes.subdata(in: offset..<end).base64EncodedString()]
                    offset = end; precondition(sender.send(chunk))
                }
            }
            precondition(sender.send(["type": "clipboardFileBegin", "id": id, "size": bytes.count, "sha256": hash, "name": "test.png", "window": 32, "destination": "downloads"]))
            // A partial losing copy cannot reach the clipboard.
            for _ in 0..<3 {
                if !queues[1-winningLane].isEmpty { receiver.receive(queues[1-winningLane].removeFirst(), lane: 1-winningLane) }
            }
            precondition(applies == 0)
            if scenario == 2 {
                // IP fails after a partial copy. BLE keeps advancing a window.
                for _ in 0..<3 { receiver.receive(queues[1].removeFirst(), lane: 1) }
                brokenIroh = true
                for _ in 0..<30 { receiver.receive(queues[0].removeFirst(), lane: 0) }
                precondition(applies == 0)
                queues[1] = []
                sender.restartLane(1); receiver.restartLane(1); brokenIroh = false
                sender.catchUp(1)
            }
            while !queues[winningLane].isEmpty { receiver.receive(queues[winningLane].removeFirst(), lane: winningLane) }
            precondition(delivered == bytes && applies == 1 && wins == [winningLane])
            precondition(sender.activeID == nil && receiver.activeID == nil)
            while !queues[1-winningLane].isEmpty { receiver.receive(queues[1-winningLane].removeFirst(), lane: 1-winningLane) }
            precondition(applies == 1)
        }
        // A corrupt full copy cannot win; a local cancellation suppresses late data.
        let race = ClipboardTransferRace(); var events = 0
        race.wire = { _, _ in true }; race.deliver = { _ in events += 1 }
        let id = UUID().uuidString
        let begin: [String: Any] = ["type": "clipboardFileBegin", "id": id, "size": 3, "sha256": String(repeating: "0", count: 64)]
        race.receive(begin, lane: 0)
        race.receive(["type": "clipboardFileChunk", "id": id, "offset": 0, "data": Data([1,2,3]).base64EncodedString()], lane: 0)
        precondition(events == 1)
        _ = race.send(["type": "clipboardFileCancel", "id": id])
        race.receive(begin, lane: 1); precondition(events == 1)
        print("PASS: both race winners, late duplicate suppression, full-copy hash verification, partial loser isolation, IP failure/replay while BLE continues and cancellation")
    }
}
