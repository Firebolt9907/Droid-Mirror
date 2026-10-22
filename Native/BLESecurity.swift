import Foundation
import CryptoKit
import Security

struct PairingKeyCache {
    private var loaded = false
    private var cached: Data?
    mutating func value(load: () -> Data?) -> Data? {
        if !loaded { cached = load(); loaded = true }
        return cached
    }
    mutating func store(_ value: Data) { cached = value; loaded = true }
}

enum BLETrust {
    static let service = "app.droidmirror.ble.v2"
    private static let cacheLock = NSLock()
    private static var cache = PairingKeyCache()
    static func key() -> Data? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        // Cache denial/missing entries too: reconnect timers must not repeatedly
        // ask for a password. Explicit pairing/configuration permits a fresh read.
        return cache.value { readKeychain() }
    }
    static func invalidate() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache = PairingKeyCache()
    }
    private static func readKeychain() -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "phone",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
    static func save(_ data: Data) throws {
        guard data.count == 32 else { throw BLECryptoError.invalid }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "phone"]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw BLECryptoError.storage
            }
        } else if updated != errSecSuccess { throw BLECryptoError.storage }
        cacheLock.lock(); cache.store(data); cacheLock.unlock()
    }
    static func random() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BLECryptoError.invalid
        }
        return Data(bytes)
    }
    static var identity: String? { key().map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
}

// This UUID reveals neither the pairing key nor permission to access data.
// It is a discovery filter; every selected peer still authenticates normally.
enum BLEDiscovery {
    static func uuid(key: Data) -> UUID {
        precondition(key.count == 32)
        var bytes = Array(HMAC<SHA256>.authenticationCode(
            for: Data("DroidMirror BLE discovery v1".utf8), using: SymmetricKey(data: key)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static let peers = UserDefaults(suiteName: "app.droidmirror.ble-peers")!
    static func remembered(key: Data) -> UUID? {
        peers.synchronize()
        return peers.string(forKey: uuid(key: key).uuidString).flatMap(UUID.init(uuidString:))
    }
    static func remember(_ peer: UUID, key: Data) {
        peers.set(peer.uuidString, forKey: uuid(key: key).uuidString)
        peers.synchronize()
    }
    static func permits(_ peer: UUID, remembered: UUID?, advertised: [UUID], discovery: UUID) -> Bool {
        peer == remembered || advertised.contains(discovery)
    }
}

enum BLECryptoError: Error { case invalid, storage, replay }

final class BLESecureSession {
    let master: SymmetricKey
    let macNonce: Data
    private var phoneNonce: Data?
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private(set) var authenticated = false
    init(key: Data, nonce: Data) throws {
        guard key.count == 32, nonce.count == 32 else { throw BLECryptoError.invalid }
        master = SymmetricKey(data: key); macNonce = nonce
    }
    var hello: [String: Any] { ["type": "hello", "nonce": macNonce.base64EncodedString()] }
    func challenge(_ object: [String: Any]) throws -> [String: Any] {
        guard sendKey == nil, let nonce = Data(base64Encoded: object["nonce"] as? String ?? ""), nonce.count == 32,
              let proof = Data(base64Encoded: object["proof"] as? String ?? ""),
              HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("phone".utf8) + macNonce + nonce, using: master)
        else { throw BLECryptoError.invalid }
        phoneNonce = nonce
        let salt = macNonce + nonce
        sendKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
            info: Data("DroidMirror BLE v2 mac".utf8), outputByteCount: 32)
        receiveKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
            info: Data("DroidMirror BLE v2 phone".utf8), outputByteCount: 32)
        let proofOut = HMAC<SHA256>.authenticationCode(for: Data("mac".utf8) + salt, using: master)
        return ["type": "finish", "proof": Data(proofOut).base64EncodedString()]
    }
    private func nonce(_ prefix: String, _ sequence: UInt64) -> Data {
        var big = sequence.bigEndian
        return Data(prefix.utf8) + withUnsafeBytes(of: &big) { Data($0) }
    }
    func seal(_ object: [String: Any]) throws -> Data {
        guard authenticated, let sendKey, sent < 9_007_199_254_740_990 else { throw BLECryptoError.invalid }
        sent += 1
        let iv = nonce("DM2M", sent)
        let plain = try JSONSerialization.data(withJSONObject: object)
        let sealed = try AES.GCM.seal(plain, using: sendKey, nonce: AES.GCM.Nonce(data: iv), authenticating: iv)
        // Base64 ciphertext contains '/'; JSON permits it literally. Avoid
        // expanding those bytes on the BLE wire without changing the envelope.
        return try JSONSerialization.data(withJSONObject: ["seq": sent, "box": sealed.combined!.base64EncodedString()],
                                          options: [.withoutEscapingSlashes])
    }
    func open(_ envelope: [String: Any]) throws -> [String: Any] {
        guard let receiveKey, let value = envelope["seq"] as? NSNumber else { throw BLECryptoError.invalid }
        let seq = value.uint64Value
        guard seq > received, seq <= 9_007_199_254_740_990 else { throw BLECryptoError.replay }
        let iv = nonce("DM2P", seq)
        guard let data = Data(base64Encoded: envelope["box"] as? String ?? ""), data.count >= 28,
              data.prefix(12) == iv else { throw BLECryptoError.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: receiveKey, authenticating: iv)
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw BLECryptoError.invalid }
        if !authenticated {
            guard object["type"] as? String == "ready" else { throw BLECryptoError.invalid }
            authenticated = true
        }
        received = seq
        return object
    }
}

struct BLEFragments {
    private var message: UInt32?
    private var total = 0
    private var bytes = Data()
    private var started = Date.distantPast
    mutating func accept(_ data: Data) -> Data? {
        guard data.count > 9, data.first == 0xd2 else { return nil }
        let b = [UInt8](data)
        let id = b[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let offset = Int(b[5]) << 8 | Int(b[6])
        let length = Int(b[7]) << 8 | Int(b[8])
        guard length > 0, length <= 8192 else { return nil }
        if offset == 0 { message = id; total = length; bytes = Data(); started = Date() }
        guard message == id, length == total, offset == bytes.count,
              Date().timeIntervalSince(started) < 15, bytes.count + data.count - 9 <= total else {
            message = nil; bytes = Data(); return nil
        }
        bytes.append(data.dropFirst(9))
        if bytes.count == total { let result = bytes; message = nil; bytes = Data(); return result }
        return nil
    }
    static func split(_ data: Data, id: UInt32, maximum: Int) -> [Data] {
        guard !data.isEmpty, data.count <= 8192, maximum > 9 else { return [] }
        let capacity = min(maximum, 512) - 9
        var frames: [Data] = []
        for offset in stride(from: 0, to: data.count, by: capacity) {
            let head: [UInt8] = [0xd2, UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
                UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id),
                UInt8(offset >> 8), UInt8(offset & 255), UInt8(data.count >> 8), UInt8(data.count & 255)]
            frames.append(Data(head) + data.subdata(in: offset..<min(data.count, offset + capacity)))
        }
        return frames
    }
}
