import Foundation
import CryptoKit
import Darwin

/// Direct-IP clipboard tunnel; identity and record keys are separate from all other lanes.
final class ClipboardIrohChannel {
    private let queue = DispatchQueue(label: "app.droidmirror.clipboard-iroh")
    private var library: UnsafeMutableRawPointer?
    private var handle: UnsafeMutableRawPointer?
    private var bulk: ClipboardBulkChannel!
    private let key: Data
    private var addresses = [String]()
    private var stopped = false // main queue only
    private let failure: () -> Void
    var connected: Bool { bulk.connected }
    var diagnostics: String { bulk.diagnostics }
    var writable: (() -> Void)? { get { bulk.writable } set { bulk.writable = newValue } }
    init(key: Data, request: @escaping () -> Bool, receive: @escaping ([String: Any]) -> Void, failure: @escaping () -> Void) {
        self.key = key; self.failure = failure
        let recordKey = Data(HMAC<SHA256>.authenticationCode(for: Data("DroidMirror clipboard Iroh v1".utf8), using: SymmetricKey(data: key)))
        bulk = ClipboardBulkChannel(key: recordKey, request: request, connect: { [weak self] _ in self?.connect() }, receive: receive, failure: failure, queueLimit: 8_000_000)
    }
    @discardableResult func open() -> Bool { bulk.open() }
    func send(_ event: [String: Any]) -> Bool { bulk.send(event) }
    func offer(_ event: [String: Any]) {
        guard let candidates = event["addresses"] as? [String], candidates.count <= 32 else { close(); return }
        addresses = candidates
        var offer = event; offer["psm"] = 1
        bulk.offer(offer)
    }
    private typealias Start = @convention(c) (UnsafePointer<UInt8>?, UnsafeMutablePointer<UInt16>?) -> UnsafeMutableRawPointer?
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Hint = @convention(c) (UnsafeMutableRawPointer?, UInt8, UnsafePointer<UInt8>?, UInt16) -> Bool
    private func connect() {
        let hints = addresses
        queue.async { [self] in
            do {
                let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                library = dlopen(host.appendingPathComponent("Contents/Frameworks/libdroidmirror_peer.dylib").path, RTLD_NOW | RTLD_LOCAL)
                guard let library, let raw = dlsym(library, "dm_peer_clipboard_start"), let rawHint = dlsym(library, "dm_peer_add_address") else { throw ClipboardBulkCodec.Failure.invalid }
                var port: UInt16 = 0
                handle = key.withUnsafeBytes { unsafeBitCast(raw, to: Start.self)($0.bindMemory(to: UInt8.self).baseAddress, &port) }
                guard let handle, port != 0 else { throw ClipboardBulkCodec.Failure.invalid }
                for encoded in hints {
                    guard let record = Data(base64Encoded: encoded), record.count == 32, record.prefix(8) == Data("DMIP0001".utf8), [4,16].contains(Int(record[8])) else { throw ClipboardBulkCodec.Failure.invalid }
                    let ip = Array(record[9..<25]), remote = UInt16(record[25]) << 8 | UInt16(record[26])
                    guard ip.withUnsafeBufferPointer({ unsafeBitCast(rawHint, to: Hint.self)(handle, record[8], $0.baseAddress, remote) }) else { throw ClipboardBulkCodec.Failure.invalid }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    var input: InputStream?, output: OutputStream?
                    Stream.getStreamsToHost(withName: "127.0.0.1", port: Int(port), inputStream: &input, outputStream: &output)
                    guard let input, let output else { self.bulk.close(); self.failure(); return }
                    self.bulk.attach(input: input, output: output)
                }
            } catch { DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }; self.bulk.close(); self.failure()
            } }
        }
    }
    func close() {
        bulk.close()
        // Serialize native teardown after bind; never block the BLE main queue.
        stopped = true
        queue.async { [self] in
            if let handle, let library, let raw = dlsym(library, "dm_peer_stop") { unsafeBitCast(raw, to: Stop.self)(handle) }
            handle = nil
            if let library { dlclose(library) }; library = nil
        }
    }
}
