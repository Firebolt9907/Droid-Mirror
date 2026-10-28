import Foundation
import IOBluetooth
@main enum PresenceRadioTests {
    static func main() {
        let key = Data(0..<32), nonce = Data(0..<16)
        precondition(PresenceRadioServer.uuid(key, "DroidMirror presence beacon v1").uuidString.lowercased() == "ead9602c-8e88-8334-828d-e6cf50915a14")
        let classicID = PresenceRadioServer.uuid(key, "DroidMirror presence classic v1")
        precondition(classicID.uuidString.lowercased() == "ad802dda-cdf9-8f79-b8ec-adb1e0abfaea")
        var bytes = classicID.uuid
        let data = withUnsafeBytes(of: &bytes) { Data($0) }
        let sdp = IOBluetoothSDPUUID(data: data)
        precondition(sdp.length == 16 && (sdp as Data) == data)
        let channel = IOBluetoothSDPDataElement(elementValue: PresenceRadioServer.channelElement as NSDictionary)!
        precondition(channel.getTypeDescriptor() == 1 && channel.getSize() == 1 && channel.getNumberValue().intValue == 0)
        let expected = ["gatt": "65f66f4793b46a6a14149d66edadf461e5e64aeeab7721dce36a121614c6a8d1", "classic": "35c4af40d8cce7e4696f7ef7a809c285a99d45a4f117f968c186305061470fae"]
        for (transport, hex) in expected {
            let proof = PresenceRadioServer.proof(key: key, nonce: nonce, transport: transport)!
            precondition(proof.map { String(format: "%02x", $0) }.joined() == hex)
            precondition(proof != PresenceRadioServer.proof(key: key, nonce: Data(repeating: 1, count: 16), transport: transport))
        }
        precondition(PresenceRadioServer.proof(key: key, nonce: Data(), transport: "gatt") == nil)
        precondition(PresenceRadioServer.proof(key: key, nonce: nonce, transport: "mac") == nil)
        print("PASS: Mac presence protocol matches Android vectors; SDP UUID bytes verified")
    }
}
