import Foundation
import CryptoKit

@main struct BLEBulkTestTests {
    static func main() throws {
        for window in [0, 1, 8, 32] {
            let master = Data(repeating: 7, count: 32), token = String(repeating: "12", count: 32)
            let id = UUID().uuidString, size = 200_000
            var control = [[String: Any]](), wire = Data(), results = [[String: Any]](), writable = false
            let runner = try BLEBulkTest(config: ["id": id, "transport": "gatt", "bytes": size, "window": window], key: master,
                control: { control.append($0); return true }, connect: { _ in preconditionFailure() },
                write: { if !writable { return false }; precondition($0.count <= 37); wire.append($0); return true },
                maximumWrite: { 37 }, finished: { results.append($0) })
            runner.start(); precondition(control.count == 1 && control[0]["type"] as? String == "bulkTestOpen")
            runner.offer(["id": id, "transport": "gatt", "token": token])
            precondition(wire.isEmpty)
            writable = true; runner.drain()
            var peer = try ClipboardBulkCodec(key: ClipboardBulkCodec.benchmarkKey(master), token: token, mac: false)
            func records() throws -> [[String: Any]] {
                var events = [[String: Any]]()
                while wire.count >= 4 {
                    let n = wire.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    if wire.count < n + 4 { break }
                    events.append(try peer.open(Data(wire.dropFirst(4).prefix(n)))); wire.removeFirst(n + 4)
                }
                return events
            }
            let hello = try records(); precondition(hello.first?["type"] as? String == "clipboardBulkHello")
            runner.receive(["type": "clipboardBulkReady"])
            let begin = try records(); precondition(begin.first?["type"] as? String == "clipboardFileBegin")
            runner.receive(["type": "clipboardFileAck", "id": id, "offset": 0])
            var received = Data(), batches = 0
            let deadline = Date().addingTimeInterval(4)
            while received.count < size && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                for event in try records() {
                    precondition(event["type"] as? String == "clipboardFileChunk" && event["offset"] as? Int == received.count)
                    received.append(Data(base64Encoded: (event["data"] as! String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!)
                    if window > 0 && received.count < size && received.count % (window * 3072) == 0 {
                        batches += 1
                        let queuedBefore = wire.count
                        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                        precondition(wire.count == queuedBefore, "Window must wait for cumulative ACK without spinning")
                        runner.receive(["type": "clipboardFileAck", "id": id, "offset": received.count])
                    }
                }
            }
            precondition(received == Data((0..<size).map { UInt8($0 % 251) }))
            let hash = SHA256.hash(data: received).map { String(format: "%02x", $0) }.joined()
            runner.receive(["type": "clipboardFileAck", "id": id, "offset": size, "elapsedMs": 100,
                "sha256": hash, "lockedStart": true, "lockedEnd": true])
            precondition(results.count == 1 && results[0]["success"] as? Bool == true && results[0]["lockedEnd"] as? Bool == true)
            precondition(control.last?["type"] as? String == "bulkTestStop")
            runner.cancel("duplicate close"); precondition(results.count == 1)
            if window == 0 { precondition(batches == 0) }
        }
        var failed = [[String: Any]]()
        let invalid = try BLEBulkTest(config: ["id": UUID().uuidString, "transport": "gatt", "bytes": 1, "window": 0],
            key: Data(repeating: 7, count: 32), control: { _ in false }, connect: { _ in }, write: { _ in false }, maximumWrite: { 20 }, finished: { failed.append($0) })
        invalid.start(); precondition(failed.count == 1 && failed[0]["success"] as? Bool == false)
        print("PASS: synthetic pattern/hash validation, locked result reporting, continuous/windowed pacing, partial GATT writes, backpressure and bounded failure")
    }
}
