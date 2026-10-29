import Foundation
@main enum PresenceRadioTests {
    static func main() {
        let key = Data(0..<32)
        precondition(PresenceBeaconAdvertiser.uuid(key).uuidString.lowercased() == "ead9602c-8e88-8334-828d-e6cf50915a14")
        precondition(PresenceBeaconAdvertiser.uuid(key) != PresenceBeaconAdvertiser.uuid(Data(repeating: 0, count: 32)))
        print("PASS: selected Mac beacon matches Android UUID and remains pairing-specific")
    }
}
