import Foundation

final class BulkTestInput: InputStream {
    private weak var sink: StreamDelegate?
    override var delegate: StreamDelegate? { get { sink } set { sink = newValue } }
    var bytes = Data(), ended = false
    init() { super.init(data: Data()) }
    override func open() {}
    override func close() { ended = true }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override var hasBytesAvailable: Bool { !bytes.isEmpty }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let count = min(len, bytes.count)
        bytes.copyBytes(to: buffer, count: count); bytes.removeFirst(count); return count
    }
}
final class BulkTestOutput: OutputStream {
    private weak var sink: StreamDelegate?
    override var delegate: StreamDelegate? { get { sink } set { sink = newValue } }
    var bytes = Data(), writable = true, ended = false
    var maximumWrite = 17, writeSizes = [Int]()
    init() { super.init(toMemory: ()) }
    override init(toMemory: ()) { super.init(toMemory: ()) }
    override func open() {}
    override func close() { ended = true }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override var hasSpaceAvailable: Bool { writable }
    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        guard writable else { return 0 }
        let count = min(maximumWrite, len); writeSizes.append(count); bytes.append(buffer, count: count); return count
    }
}
@main struct ClipboardBulkTests {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid bulk record accepted") } catch {}
    }
    static func main() throws {
        let key = Data(repeating: 7, count: 32), token = String(repeating: "12", count: 32)
        var mac = try ClipboardBulkCodec(key: key, token: token)
        let id = "EFB1ED3E-5AF7-4CC3-964D-06935900C2BB"
        let bytes = Data((0..<3072).map { UInt8($0 % 251) })
        let chunk: [String: Any] = ["type": "clipboardFileChunk", "id": id, "offset": 3072,
            "data": bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")]
        let events: [[String: Any]] = [["type": "clipboardBulkHello"],
            ["type": "clipboardFileBegin", "id": id, "size": 6144, "name": "測試.png"], chunk]
        let records = try events.map { try mac.seal($0) }
        precondition(records[2].count == 3117, "Binary chunk must not carry Base64/JSON overhead")
        rejects { _ = try mac.seal(["type": "clipboardSet", "text": "forbidden"]) }
        rejects { _ = try mac.seal(["type": "mediaCommand", "action": "play"]) }
        // Phone-to-Mac chunks are bounded by an explicit reverse transfer declaration.
        let reply: [[String: Any]] = [["type": "clipboardBulkReady"], ["type": "clipboardFileAck", "id": id, "offset": 6144],
            ["type": "clipboardFileBegin", "id": id, "size": 6144, "name": "測試.png"], chunk]
        let input: [String: Any] = ["key": key.base64EncodedString(), "token": token,
            "records": records.map { $0.base64EncodedString() }, "reply": reply]
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = ["-cp", CommandLine.arguments[2], "ClipboardBulkSecurityPeer"]
        let source = Pipe(), output = Pipe(); process.standardInput = source; process.standardOutput = output
        try process.run()
        source.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input)); try source.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(response["benchmarkKey"] as? String == ClipboardBulkCodec.benchmarkKey(key).base64EncodedString())
        var benchmarkPeer = try ClipboardBulkCodec(key: ClipboardBulkCodec.benchmarkKey(key), token: token, mac: false)
        rejects { _ = try benchmarkPeer.open(records[0]) }
        let decoded = response["decoded"] as! [[String: Any]]
        precondition(decoded[1]["name"] as? String == "測試.png")
        precondition(decoded[2]["data"] as? String == chunk["data"] as? String && decoded[2]["id"] as? String == id)
        let incoming = (response["records"] as! [String]).map { Data(base64Encoded: $0)! }
        for (i, record) in incoming.enumerated() {
            let value = try mac.open(record)
            precondition(value["type"] as? String == reply[i]["type"] as? String)
            rejects { _ = try mac.open(record) }
        }
        var changed = incoming[0]; changed[changed.count - 1] ^= 1
        var fresh = try ClipboardBulkCodec(key: key, token: token)
        rejects { _ = try fresh.open(changed) }
        var wrong = try ClipboardBulkCodec(key: key, token: String(repeating: "ab", count: 32))
        rejects { _ = try wrong.open(incoming[0]) }
        rejects { _ = try fresh.open(Data(repeating: 0, count: 100000)) }
        // A fresh offer cannot decode a record from an earlier channel or skip a sequence.
        rejects { _ = try fresh.open(incoming[1]) }
        var requests = 0, connects = 0, failures = 0, delivered = [[String: Any]]()
        let owner = ClipboardBulkChannel(key: key, request: { requests += 1; return true },
            connect: { _ in connects += 1 }, receive: { delivered.append($0) }, failure: { failures += 1 })
        precondition(requests == 0 && connects == 0, "Bulk channel opens lazily")
        precondition(!owner.send(["type": "clipboardSet", "text": "not a file"]))
        precondition(owner.send(events[1])); precondition(owner.send(chunk)); precondition(requests == 1)
        let offer: [String: Any] = ["psm": 128, "token": token]
        owner.offer(offer); owner.offer(offer); precondition(connects == 1)
        let streamIn = BulkTestInput(), streamOut = BulkTestOutput()
        owner.attach(input: streamIn, output: streamOut)
        owner.stream(streamOut, handle: .hasSpaceAvailable)
        var peer = try ClipboardBulkCodec(key: key, token: token, mac: false)
        func packets(_ bytes: Data) -> [Data] {
            var data = bytes, result = [Data]()
            while data.count >= 4 {
                let size = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                precondition(data.count >= 4 + size)
                result.append(Data(data.dropFirst(4).prefix(size))); data.removeFirst(4 + size)
            }
            precondition(data.isEmpty); return result
        }
        let hello = packets(streamOut.bytes); precondition(hello.count == 1)
        let greeting = try peer.open(hello[0]); precondition(greeting["type"] as? String == "clipboardBulkHello")
        streamOut.bytes.removeAll()
        func frame(_ value: [String: Any]) throws -> Data {
            let body = try peer.seal(value); var size = UInt32(body.count).bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + body
        }
        let readyFrame = try frame(["type": "clipboardBulkReady"])
        streamIn.bytes = readyFrame.prefix(3); owner.stream(streamIn, handle: .hasBytesAvailable)
        precondition(streamOut.bytes.isEmpty, "File data waits for authenticated peer readiness")
        streamIn.bytes = readyFrame.dropFirst(3); owner.stream(streamIn, handle: .hasBytesAvailable)
        owner.stream(streamOut, handle: .hasSpaceAvailable)
        let files = packets(streamOut.bytes); precondition(files.count == 2)
        for (i, packet) in files.enumerated() { let event = try peer.open(packet); precondition(event["type"] as? String == ["clipboardFileBegin", "clipboardFileChunk"][i]) }
        streamOut.bytes.removeAll()
        for _ in 0..<100 { owner.stream(streamOut, handle: .hasSpaceAvailable) }
        precondition(streamOut.bytes.isEmpty, "Idle channel has no keepalive traffic")
        let ack = try frame(["type": "clipboardFileAck", "id": id, "offset": 6144])
        streamIn.bytes = ack; owner.stream(streamIn, handle: .hasBytesAvailable)
        precondition(delivered.last?["offset"] as? Int == 6144)
        // A full window shares large stream writes while retaining individual AEAD records.
        streamOut.bytes.removeAll(); streamOut.writeSizes.removeAll(); streamOut.maximumWrite = 65536
        for _ in 0..<32 { precondition(owner.send(chunk)) }
        precondition(streamOut.bytes.isEmpty, "Flush waits until the producer has queued its window")
        owner.stream(streamOut, handle: .hasSpaceAvailable)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(streamOut.writeSizes.first == 65536)
        let batched = packets(streamOut.bytes); precondition(batched.count == 32)
        for packet in batched { let value = try peer.open(packet); precondition(value["type"] as? String == "clipboardFileChunk") }
        streamOut.writable = false
        var bounded = false
        for _ in 0..<100 { if !owner.send(chunk) { bounded = true; break } }
        precondition(bounded, "Unsent stream data is bounded")
        owner.close(); precondition(streamIn.ended && streamOut.ended && failures == 0)
        precondition(!owner.send(chunk))
        var badFailures = 0
        let invalid = ClipboardBulkChannel(key: key, request: { true }, connect: { _ in }, receive: { _ in preconditionFailure() }, failure: { badFailures += 1 })
        invalid.offer(offer)
        let badIn = BulkTestInput(), badOut = BulkTestOutput(); invalid.attach(input: badIn, output: badOut)
        badIn.bytes = Data([0, 1, 0, 1]); invalid.stream(badIn, handle: .hasBytesAvailable)
        precondition(badFailures == 1 && badIn.ended && badOut.ended)
        print("PASS: lazy opening, authenticated readiness, partial I/O, file-only routing, idle silence, bounded backpressure, malformed frames and explicit teardown")
        print("PASS: Swift↔Android clipboard-only binary records, Unicode, raw chunks, mutual key possession, tampering, replay, session binding and bounds")
    }
}
