import Foundation
import CryptoKit

/// This one-use credential protects key delivery only; it never replaces the saved pairing key.
enum QRPairingProtocol {
    static let characteristic = "A946DDA2-7E71-4ACD-B670-F77C3D715891"
    static func context(service: String, mac: String) -> Data {
        Data("DroidMirror QR key transfer v1|\(service.uppercased())|\(mac.uppercased())".utf8)
    }
    static func acknowledgement(packet: Data, secret: Data, service: String, mac: String) -> Data {
        let input = context(service: service, mac: mac) + Data("|saved|".utf8) + packet
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)).prefix(16))
    }
    static func open(_ packet: Data, secret: Data, service: String, mac: String) throws -> Data {
        guard packet.count == 60, secret.count == 32 else { throw CocoaError(.coderInvalidValue) }
        let box = try AES.GCM.SealedBox(combined: packet)
        let key = try AES.GCM.open(box, using: SymmetricKey(data: secret),
                                   authenticating: context(service: service, mac: mac))
        guard key.count == 32 else { throw CocoaError(.coderInvalidValue) }
        return key
    }
}
