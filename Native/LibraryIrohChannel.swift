import Foundation
import Darwin

/// Read-only bulk connection with its own Iroh identity, endpoint and ALPN.
/// The fresh capability is delivered exclusively over authenticated BLE.
protocol LibraryBulkChannel: AnyObject {
    var ready: Bool { get }
    func connect(key: Data, token: String, addresses: [String], completion: @escaping (Bool) -> Void)
    func request(_ command: [String: Any], completion: @escaping ([String: Any]?) -> Void)
    func close()
}

final class LibraryIrohChannel: LibraryBulkChannel {
    private let queue = DispatchQueue(label: "app.droidmirror.library-iroh", qos: .utility)
    private var library: UnsafeMutableRawPointer?
    private var handle: UnsafeMutableRawPointer?
    private var descriptor: Int32 = -1
    private var sequence = 1
    private(set) var ready = false // main queue only
    private var stopped = false // worker queue only
    private typealias Start = @convention(c) (UnsafePointer<UInt8>?, UnsafeMutablePointer<UInt16>?) -> UnsafeMutableRawPointer?
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Hint = @convention(c) (UnsafeMutableRawPointer?, UInt8, UnsafePointer<UInt8>?, UInt16) -> Bool
    func connect(key: Data, token: String, addresses: [String], completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            var success = false
            do {
                guard !stopped, key.count == 32, addresses.count <= 32 else { throw Failure.invalid }
                let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                library = dlopen(host.appendingPathComponent("Contents/Frameworks/libdroidmirror_peer.dylib").path, RTLD_NOW | RTLD_LOCAL)
                guard let library, let rawStart = dlsym(library, "dm_peer_library_start"),
                      let rawHint = dlsym(library, "dm_peer_add_address") else { throw Failure.invalid }
                let start = unsafeBitCast(rawStart, to: Start.self)
                let hint = unsafeBitCast(rawHint, to: Hint.self)
                var port: UInt16 = 0
                handle = key.withUnsafeBytes { start($0.bindMemory(to: UInt8.self).baseAddress, &port) }
                guard let handle, port != 0 else { throw Failure.invalid }
                for encoded in addresses {
                    guard let record = Data(base64Encoded: encoded), record.count == 32,
                          record.prefix(8) == Data("DMIP0001".utf8), [4, 16].contains(Int(record[8])) else { throw Failure.invalid }
                    let family = record[8]; var ip = [UInt8](record[9..<25])
                    let remotePort = UInt16(record[25]) << 8 | UInt16(record[26])
                    guard ip.withUnsafeMutableBufferPointer({ hint(handle, family, $0.baseAddress, remotePort) }) else { throw Failure.invalid }
                }
                descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw Failure.invalid }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                var one: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard connected == 0 else { throw Failure.invalid }
                try write(["token": token])
                let response = try read()
                guard response["success"] as? Bool == true, response["seq"] as? Int == 0 else { throw Failure.invalid }
                success = true
            } catch { teardown() }
            let result = success
            DispatchQueue.main.async { [weak self] in self?.ready = result; completion(result) }
        }
    }
    func request(_ command: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        queue.async { [self] in
            var response: [String: Any]?
            do {
                guard !stopped, descriptor >= 0, ["appCatalogRequest", "appIconRequest"].contains(command["type"] as? String ?? "") else { throw Failure.invalid }
                var value = command; value["seq"] = sequence
                try write(value)
                let result = try read()
                guard result["seq"] as? Int == sequence else { throw Failure.invalid }
                sequence += 1; response = result
            } catch { teardown() }
            let result = response
            DispatchQueue.main.async { [weak self] in
                if result == nil { self?.ready = false }
                completion(result)
            }
        }
    }
    func close() {
        ready = false
        queue.async { [self] in stopped = true; teardown() }
    }
    private func teardown() {
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
        if let handle, let library, let raw = dlsym(library, "dm_peer_stop") { unsafeBitCast(raw, to: Stop.self)(handle) }
        handle = nil
        if let library { dlclose(library) }; library = nil
    }
    private enum Failure: Error { case invalid }
    private func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 65536 else { throw Failure.invalid }
        var size = UInt32(data.count).bigEndian
        var bytes = withUnsafeBytes(of: &size) { Data($0) }; bytes.append(data)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            let deadline = Date().addingTimeInterval(5)
            while offset < raw.count {
                guard Date() < deadline else { throw Failure.invalid }
                let sent = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { throw Failure.invalid }; offset += sent
            }
        }
    }
    private func receive(_ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            let deadline = Date().addingTimeInterval(5)
            while offset < size {
                guard Date() < deadline else { throw Failure.invalid }
                let count = Darwin.recv(descriptor, raw.baseAddress!.advanced(by: offset), size - offset, 0)
                guard count > 0 else { throw Failure.invalid }; offset += count
            }
        }
        return data
    }
    private func read() throws -> [String: Any] {
        let prefix = try receive(4)
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...98304).contains(size), let value = try JSONSerialization.jsonObject(with: receive(size)) as? [String: Any] else { throw Failure.invalid }
        return value
    }
}
