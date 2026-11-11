import Foundation
import CryptoKit
import CoreBluetooth

/// Explicit synthetic upload. It never touches a pasteboard or invokes ClipboardSync.
final class BLEBulkTest {
    let id: String
    private let size: Int
    private let window: Int
    private let transport: String
    private let key: Data
    private let control: ([String: Any]) -> Bool
    private let connect: (UInt16) -> Void
    private let write: (Data) -> Bool
    private let maximumWrite: () -> Int
    private let finished: ([String: Any]) -> Void
    private var ip: ClipboardIrohChannel?
    private var channel: ClipboardBulkChannel?
    private var codec: ClipboardBulkCodec?
    private var frames = [Data]()
    private var frameOffset = 0
    private var queued = 0
    private var sent = 0
    private var acknowledged = 0
    private var startedAt: TimeInterval?
    private var closed = false
    private var pumping = false
    private var began = false
    private var offered = false
    private let openedAt = ProcessInfo.processInfo.systemUptime
    private let data: Data
    private var stalls = 0
    private var wireSent = 0
    var diagnostics: String { ip?.diagnostics ?? channel?.diagnostics ?? "gattQueued=\(queued) sent=\(sent) wire=\(wireSent) backpressure=\(stalls)" }

    init(config: [String: Any], key: Data, control: @escaping ([String: Any]) -> Bool,
         connect: @escaping (UInt16) -> Void, write: @escaping (Data) -> Bool,
         maximumWrite: @escaping () -> Int, finished: @escaping ([String: Any]) -> Void) throws {
        guard let id = config["id"] as? String, UUID(uuidString: id) != nil,
              let size = config["bytes"] as? Int, (1...4_000_000).contains(size),
              let window = config["window"] as? Int, [0, 1, 8, 32].contains(window),
              let transport = config["transport"] as? String, ["l2cap", "gatt", "iroh"].contains(transport) else { throw ClipboardBulkCodec.Failure.invalid }
        self.id = id.uppercased(); self.size = size; self.window = window; self.transport = transport
        self.key = ClipboardBulkCodec.benchmarkKey(key); self.control = control; self.connect = connect
        self.write = write; self.maximumWrite = maximumWrite; self.finished = finished
        self.data = Data((0..<size).map { UInt8($0 % 251) })
    }
    func start() {
        guard control(["type": "bulkTestOpen", "id": id, "bytes": size, "window": window, "transport": transport]) else { cancel("request not queued"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.cancel("deadline") }
    }
    func offer(_ event: [String: Any]) {
        guard !closed, !offered, event["id"] as? String == id, event["transport"] as? String == transport else { return }
        offered = true
        if transport == "iroh" {
            let bulk = ClipboardIrohChannel(key: key, request: { true }, receive: { [weak self] in self?.receive($0) }, failure: { [weak self] in self?.cancel("iroh failed") })
            ip = bulk; bulk.writable = { [weak self] in self?.schedulePump() }
            bulk.offer(event)
            guard bulk.send(["type": "clipboardFileBegin", "id": id, "name": "synthetic.bin", "size": size, "window": window]) else { cancel("begin not queued"); return }
        } else if transport == "l2cap" {
            let bulk = ClipboardBulkChannel(key: key, request: { true }, connect: connect,
                receive: { [weak self] in self?.receive($0) }, failure: { [weak self] in self?.cancel("channel failed") })
            channel = bulk
            bulk.writable = { [weak self] in self?.schedulePump() }
            bulk.offer(event)
            guard bulk.send(["type": "clipboardFileBegin", "id": id, "name": "synthetic.bin", "size": size, "window": window]) else { cancel("begin not queued"); return }
        } else {
            guard let token = event["token"] as? String, let fresh = try? ClipboardBulkCodec(key: key, token: token) else { cancel("invalid offer"); return }
            codec = fresh
            guard send(["type": "clipboardBulkHello"]) else { cancel("hello not queued"); return }
            drain()
        }
    }
    func attach(_ value: CBL2CAPChannel?, error: Error?) { channel?.attach(value, error: error) }
    func receive(_ event: [String: Any]) {
        guard !closed else { return }
        let type = event["type"] as? String
        if transport == "gatt", type == "clipboardBulkReady" {
            guard !began else { cancel("duplicate readiness"); return }; began = true
            guard send(["type": "clipboardFileBegin", "id": id, "name": "synthetic.bin", "size": size, "window": window]) else { cancel("begin not queued"); return }
            drain(); return
        }
        guard type == "clipboardFileAck", event["id"] as? String == id, let offset = event["offset"] as? Int,
              offset >= acknowledged, offset <= sent else { cancel("invalid acknowledgement"); return }
        acknowledged = offset
        if offset == 0 && startedAt == nil { startedAt = ProcessInfo.processInfo.systemUptime; began = true }
        if offset == size {
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard event["sha256"] as? String == expected, let milliseconds = event["elapsedMs"] as? Int, milliseconds > 0 else { cancel("digest or count mismatch"); return }
            let result: [String: Any] = ["id": id, "success": true, "transport": transport, "window": window,
                "bytes": size, "receiverMs": milliseconds, "receiverKBps": Double(size) / Double(milliseconds),
                "senderMs": Int((ProcessInfo.processInfo.systemUptime - (startedAt ?? openedAt)) * 1000),
                "totalMs": Int((ProcessInfo.processInfo.systemUptime - openedAt) * 1000),
                "lockedStart": event["lockedStart"] as? Bool ?? false, "lockedEnd": event["lockedEnd"] as? Bool ?? false,
                "sha256": expected, "gattWriteSize": maximumWrite(), "diagnostics": diagnostics]
            finish(result); return
        }
        if window > 0 && offset != sent { cancel("unexpected window acknowledgement"); return }
        schedulePump()
    }
    private func send(_ event: [String: Any]) -> Bool {
        if let ip { return ip.send(event) }
        if let channel { return channel.send(event) }
        guard var fresh = codec, queued < 131072 else { return false }
        do {
            let packet = try fresh.seal(event)
            var size = UInt32(packet.count).bigEndian
            let frame = withUnsafeBytes(of: &size) { Data($0) } + packet
            frames.append(frame); queued += frame.count; codec = fresh
            return true
        } catch { return false }
    }
    private func schedulePump() {
        guard !closed, !pumping, startedAt != nil, sent < (window == 0 ? size : min(size, acknowledged + window * 3072)) else { return }
        pumping = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.pumping = false; self.pump()
        }
    }
    private func pump() {
        guard !closed, startedAt != nil else { return }
        let endOfWindow = window == 0 ? size : min(size, acknowledged + window * 3072)
        while sent < endOfWindow {
            let end = min(sent + 3072, size)
            let event: [String: Any] = ["type": "clipboardFileChunk", "id": id, "offset": sent,
                "data": data.subdata(in: sent..<end).base64EncodedString()]
            guard send(event) else { break }
            sent = end
        }
        if transport == "gatt" { drain() }
    }
    func drain() {
        guard !closed, transport == "gatt" else { return }
        var budget = 8192
        while !frames.isEmpty && budget > 0 {
            let n = min(maximumWrite(), frames[0].count - frameOffset, budget)
            guard n > 0, write(frames[0].subdata(in: frameOffset..<(frameOffset + n))) else { stalls += 1; break }
            frameOffset += n; queued -= n; wireSent += n; budget -= n
            if frameOffset == frames[0].count { frames.removeFirst(); frameOffset = 0 }
        }
        if queued < 65536 { schedulePump() }
        if budget == 0 && !frames.isEmpty { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }
    func cancel(_ reason: String) {
        guard !closed else { return }
        finish(["id": id, "success": false, "transport": transport, "reason": reason, "diagnostics": diagnostics])
    }
    private func finish(_ result: [String: Any]) {
        guard !closed else { return }; closed = true
        _ = control(["type": "bulkTestStop", "id": id])
        ip?.writable = nil; ip?.close(); ip = nil
        channel?.writable = nil; channel?.close(); channel = nil; codec = nil; frames.removeAll()
        finished(result)
    }
}
