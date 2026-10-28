import Foundation

@main
struct QRPairingTests {
    static func main() throws {
        let vector = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")
        let packet = Data(base64Encoded: String(vector[0]))!
        let secret = Data((64..<96).map(UInt8.init))
        let service = "7D6167CB-4DC7-4784-AB5F-045C69AFA628", mac = "AA:BB:CC:DD:EE:FF"
        let key = try QRPairingProtocol.open(packet, secret: secret, service: service, mac: mac)
        precondition(key == Data((0..<32).map(UInt8.init)), "Must receive the existing key byte for byte")
        precondition(QRPairingProtocol.acknowledgement(packet: packet, secret: secret, service: service, mac: mac)
            == Data(base64Encoded: String(vector[1]))!, "Java must authenticate the Swift save confirmation")
        func reject(_ data: Data, _ secret: Data, _ service: String, _ mac: String) {
            do { _ = try QRPairingProtocol.open(data, secret: secret, service: service, mac: mac); fatalError("Accepted invalid transfer") }
            catch {}
        }
        for index in packet.indices {
            var modified = packet; modified[index] ^= 1
            reject(modified, secret, service, mac)
        }
        reject(packet, Data(repeating: 0, count: 32), service, mac)
        reject(packet, secret, UUID().uuidString, mac)
        reject(packet, secret, service, "00:00:00:00:00:00")
        reject(Data(packet.dropLast()), secret, service, mac)
        reject(packet + Data([0]), secret, service, mac)
        reject(packet, Data(secret.dropLast()), service, mac)
        print("PASS: Java → Swift existing-key transfer; Swift → Java save proof; tampering every packet byte, wrong invitation/target/secret and invalid lengths rejected")
    }
}
