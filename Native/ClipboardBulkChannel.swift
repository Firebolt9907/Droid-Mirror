import Foundation
import CoreBluetooth
import CryptoKit

/// Separate keys and sequences: bulk records never share the GATT cipher's nonce space.
struct ClipboardBulkCodec {
    static let maximum = 65_536
    static func benchmarkKey(_ master: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("DroidMirror synthetic BLE benchmark v1".utf8), using: SymmetricKey(data: master)))
    }
    static let files: Set<String> = ["clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel"]
    static let controls = files.subtracting(["clipboardFileChunk"]).union(["clipboardBulkHello", "clipboardBulkReady"])
    enum Failure: Error { case invalid }
    private let sending: SymmetricKey
    private let receiving: SymmetricKey
    private let sendPrefix: Data
    private let receivePrefix: Data
    private var sendingTransfer: (id: String, size: Int)?
    private var receivingTransfer: (id: String, size: Int)?
    private func declaration(_ event: [String: Any]) throws -> (id: String, size: Int) {
        guard let id = event["id"] as? String, UUID(uuidString: id) != nil,
              let size = event["size"] as? Int else { throw Failure.invalid }
        let destination = event["destination"] as? String ?? "clipboard"
        guard ["clipboard", "downloads", "install"].contains(destination),
              destination == "install" ? ApkInstallPolicy.allowed(size) && ApkInstallPolicy.nameAllowed(event["name"] as? String ?? "") : ClipboardFilePolicy.allowed(size) else { throw Failure.invalid }
        return (id.uppercased(), size)
    }
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    init(key: Data, token: String, mac: Bool = true) throws {
        guard key.count == 32, token.count == 64 else { throw Failure.invalid }
        var salt = Data()
        for i in stride(from: 0, to: 64, by: 2) {
            let start = token.index(token.startIndex, offsetBy: i)
            guard let byte = UInt8(token[start..<token.index(start, offsetBy: 2)], radix: 16) else { throw Failure.invalid }
            salt.append(byte)
        }
        func derive(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt,
                info: Data(("DroidMirror clipboard L2CAP v1 " + direction).utf8), outputByteCount: 32)
        }
        sending = derive(mac ? "mac" : "phone"); receiving = derive(mac ? "phone" : "mac")
        sendPrefix = Data((mac ? "DCCM" : "DCCP").utf8); receivePrefix = Data((mac ? "DCCP" : "DCCM").utf8)
    }
    private func sequence(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    mutating func seal(_ event: [String: Any]) throws -> Data {
        guard sent < 9_007_199_254_740_990, let type = event["type"] as? String else { throw Failure.invalid }
        if type == "clipboardFileBegin" { sendingTransfer = try declaration(event) }
        var body: Data
        if type == "clipboardFileChunk" {
            guard let id = event["id"] as? String, let uuid = UUID(uuidString: id),
                  let offset = event["offset"] as? Int, offset >= 0, sendingTransfer?.id == id.uppercased(),
                  let encoded = event["data"] as? String, encoded.utf8.count <= 4096,
                  let bytes = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
                  !bytes.isEmpty, bytes.count <= 3072, offset <= (sendingTransfer?.size ?? 0) - bytes.count else { throw Failure.invalid }
            body = Data([2]); var raw = uuid.uuid
            withUnsafeBytes(of: &raw) { body.append(contentsOf: $0) }
            var big = UInt32(offset).bigEndian
            withUnsafeBytes(of: &big) { body.append(contentsOf: $0) }
            body.append(bytes)
        } else {
            guard Self.controls.contains(type) else { throw Failure.invalid }
            body = Data([1]) + (try JSONSerialization.data(withJSONObject: event))
        }
        guard body.count + 24 <= Self.maximum else { throw Failure.invalid }
        let next = sent + 1, header = sequence(next)
        let nonce = try AES.GCM.Nonce(data: sendPrefix + header)
        let sealed = try AES.GCM.seal(body, using: sending, nonce: nonce, authenticating: sendPrefix + header)
        sent = next
        return header + sealed.ciphertext + sealed.tag
    }
    mutating func open(_ record: Data) throws -> [String: Any] {
        guard record.count >= 25, record.count <= Self.maximum else { throw Failure.invalid }
        let header = Data(record.prefix(8)), seq = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard seq == received + 1, seq <= 9_007_199_254_740_990 else { throw Failure.invalid }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: receivePrefix + header),
            ciphertext: record.dropFirst(8).dropLast(16), tag: record.suffix(16))
        let body = try AES.GCM.open(box, using: receiving, authenticating: receivePrefix + header)
        let event: [String: Any]
        if body.first == 2 {
            let raw = [UInt8](body)
            guard (22...3093).contains(raw.count) else { throw Failure.invalid }
            let id = UUID(uuid: (raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7],raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15],raw[16]))
            let offset = raw[17...20].reduce(0) { ($0 << 8) | Int($1) }
            guard receivingTransfer?.id == id.uuidString.uppercased(), offset <= (receivingTransfer?.size ?? 0) - (raw.count - 21) else { throw Failure.invalid }
            event = ["type": "clipboardFileChunk", "id": id.uuidString, "offset": offset,
                "data": Data(raw.dropFirst(21)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")]
        } else {
            guard body.first == 1, let value = try JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any],
                  let type = value["type"] as? String, Self.controls.contains(type) else { throw Failure.invalid }
            event = value
        }
        if event["type"] as? String == "clipboardFileBegin" { receivingTransfer = try declaration(event) }
        received = seq
        return event
    }
}

/// Main-run-loop stream owner. No idle timer, polling loop or extra heartbeat.
final class ClipboardBulkChannel: NSObject, StreamDelegate {
    private let request: () -> Bool
    private let connect: (UInt16) -> Void
    private let receive: ([String: Any]) -> Void
    private let failure: () -> Void
    private let key: Data
    private let queueLimit: Int
    var connected: Bool { established && !closed }
    var writable: (() -> Void)?
    private var codec: ClipboardBulkCodec?
    private var channel: CBL2CAPChannel?
    private var input: InputStream?
    private var output: OutputStream?
    private var pending = [([String: Any], Int)]()
    private var frames = [(Data, Int)]()
    private var frameOffset = 0
    private var buffered = Data()
    private var reserved = 0
    private var opening = false
    private var established = false
    private var closed = false
    private var deadlineGeneration = 0
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var watchingWrites = false
    private var flushScheduled = false
    private var wireSent = 0
    private var wireReceived = 0
    private var largestWrite = 0
    private var backpressure = 0
    // Published only in the existing local diagnostics; never sent over BLE.
    var diagnostics: String {
        "ready=\(established) queuedCost=\(reserved) frames=\(frames.count) tx=\(wireSent) rx=\(wireReceived) maxWrite=\(largestWrite) backpressure=\(backpressure)"
    }
    private(set) var psm: UInt16?
    private var token: String?
    init(key: Data, request: @escaping () -> Bool, connect: @escaping (UInt16) -> Void,
         receive: @escaping ([String: Any]) -> Void, failure: @escaping () -> Void, queueLimit: Int = 262144) {
        self.key = key; self.queueLimit = queueLimit; self.request = request; self.connect = connect; self.receive = receive; self.failure = failure
    }
    func send(_ event: [String: Any]) -> Bool {
        guard !closed, let type = event["type"] as? String, ClipboardBulkCodec.files.contains(type),
              let data = try? JSONSerialization.data(withJSONObject: event), reserved + data.count + 64 <= queueLimit else { return false }
        let cost = data.count + 64
        reserved += cost
        if established { enqueue(event, cost: cost) } else { pending.append((event, cost)) }
        return open()
    }
    @discardableResult func open() -> Bool {
        guard !closed else { return false }
        if !opening && channel == nil {
            opening = true; watchOpening()
            if !request() { fail(); return false }
        }
        return !closed
    }
    func offer(_ event: [String: Any]) {
        guard !closed, let raw = event["psm"] as? Int, (1...255).contains(raw),
              let token = event["token"] as? String else { fail(); return }
        if self.token == token { return }
        guard self.token == nil, let cipher = try? ClipboardBulkCodec(key: key, token: token) else { fail(); return }
        self.token = token; psm = UInt16(raw); codec = cipher
        NSLog("DroidMirror clipboard L2CAP connecting psm=%d", raw)
        opening = true; watchOpening(); connect(UInt16(raw))
    }
    func attach(_ value: CBL2CAPChannel?, error: Error?) {
        guard !closed, error == nil, let value, value.psm == psm, channel == nil else {
            value?.inputStream.close(); value?.outputStream.close(); fail(); return
        }
        NSLog("DroidMirror clipboard L2CAP streams attached")
        channel = value
        attach(input: value.inputStream, output: value.outputStream)
    }
    // Keeping stream framing separate also permits exercising partial I/O without a live radio.
    func attach(input: InputStream, output: OutputStream) {
        guard !closed, self.input == nil, codec != nil else { input.close(); output.close(); fail(); return }
        self.input = input; self.output = output
        input.delegate = self; output.delegate = self
        input.schedule(in: .main, forMode: .common); output.schedule(in: .main, forMode: .common)
        input.open(); output.open()
        enqueue(["type": "clipboardBulkHello"], cost: 0)
    }
    private func watchOpening() {
        deadlineGeneration += 1; let epoch = deadlineGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed, !self.established, self.deadlineGeneration == epoch else { return }
            self.fail()
        }
    }
    private func enqueue(_ event: [String: Any], cost: Int) {
        do {
            guard var cipher = codec else { throw ClipboardBulkCodec.Failure.invalid }
            let data = try cipher.seal(event); codec = cipher
            var size = UInt32(data.count).bigEndian
            let head = withUnsafeBytes(of: &size) { Data($0) }
            if frames.isEmpty { lastProgress = ProcessInfo.processInfo.systemUptime }
            frames.append((head + data, cost)); watchWrites(); scheduleFlush()
        } catch { fail() }
    }
    private func watchWrites() {
        guard !watchingWrites else { return }
        watchingWrites = true; lastProgress = ProcessInfo.processInfo.systemUptime
        checkWrites()
    }
    private func checkWrites() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.closed, self.watchingWrites else { return }
            if self.frames.isEmpty { self.watchingWrites = false; return }
            if ProcessInfo.processInfo.systemUptime - self.lastProgress >= 60 { self.fail() }
            else { self.checkWrites() }
        }
    }
    private func scheduleFlush() {
        guard !closed, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false; self.flush()
        }
    }
    private func flush() {
        guard !closed, let output else { return }
        var budget = 65536
        while !frames.isEmpty && output.hasSpaceAvailable && budget > 0 {
            // The stream preserves bytes, not record boundaries. Coalesce a window
            // so each 3 KiB record does not leave a short Bluetooth SDU behind it.
            var batch = Data()
            for (index, frame) in frames.enumerated() {
                let start = index == 0 ? frameOffset : 0
                let count = min(frame.0.count - start, budget - batch.count)
                batch.append(frame.0.subdata(in: start..<(start + count)))
                if batch.count == budget { break }
            }
            let written = batch.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base, maxLength: batch.count)
            }
            if written < 0 || written > batch.count { fail(); return }
            if written == 0 { return }
            wireSent += written; largestWrite = max(largestWrite, written)
            budget -= written; lastProgress = ProcessInfo.processInfo.systemUptime
            var remaining = written
            while remaining > 0 {
                let consumed = min(remaining, frames[0].0.count - frameOffset)
                frameOffset += consumed; remaining -= consumed
                if frameOffset == frames[0].0.count { reserved -= frames.removeFirst().1; frameOffset = 0 }
            }
        }
        if !frames.isEmpty && !output.hasSpaceAvailable { backpressure += 1 }
        if budget <= 0 && !frames.isEmpty { scheduleFlush() }
        if reserved < 131072 { writable?() }
    }
    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard !closed else { return }
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { fail(); return }
        if eventCode.contains(.hasSpaceAvailable) { flush() }
        if eventCode.contains(.hasBytesAvailable), let input = stream as? InputStream {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0, buffered.count + count <= ClipboardBulkCodec.maximum + 8196 else { fail(); return }
            wireReceived += count
            buffered.append(contentsOf: bytes.prefix(count))
            do {
                while buffered.count >= 4 {
                    let size = buffered.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard (25...ClipboardBulkCodec.maximum).contains(size) else { throw ClipboardBulkCodec.Failure.invalid }
                    if buffered.count < size + 4 { break }
                    let packet = Data(buffered.dropFirst(4).prefix(size)); buffered.removeFirst(size + 4)
                    guard var cipher = codec else { throw ClipboardBulkCodec.Failure.invalid }
                    let value = try cipher.open(packet); codec = cipher
                    if !established {
                        guard value["type"] as? String == "clipboardBulkReady" else { throw ClipboardBulkCodec.Failure.invalid }
                        NSLog("DroidMirror clipboard L2CAP authenticated")
                        established = true; deadlineGeneration += 1
                        let queued = pending; pending.removeAll()
                        for (event, cost) in queued { enqueue(event, cost: cost) }
                    } else {
                        guard let type = value["type"] as? String, ClipboardBulkCodec.files.contains(type) else { throw ClipboardBulkCodec.Failure.invalid }
                        receive(value)
                    }
                    if closed { return }
                }
            } catch { fail() }
        }
    }
    private func fail() { guard !closed else { return }; NSLog("DroidMirror clipboard L2CAP failed established=%d queuedBytes=%d", established ? 1 : 0, reserved); close(); failure() }
    func close() {
        guard !closed else { return }; closed = true; deadlineGeneration += 1
        for stream in [input as Stream?, output as Stream?].compactMap({ $0 }) {
            stream.delegate = nil; stream.close(); stream.remove(from: .main, forMode: .common)
        }
        channel = nil; input = nil; output = nil; codec = nil; frames.removeAll(); pending.removeAll(); buffered.removeAll(); reserved = 0
    }
    deinit { close() }
}
