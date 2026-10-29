import Foundation
import CoreBluetooth
import CryptoKit

/// Passive discovery hint only. No GATT database, challenge endpoint, or Classic service.
final class PresenceBeaconAdvertiser: NSObject, CBPeripheralManagerDelegate {
    private var peripheral: CBPeripheralManager!
    private var key: Data?
    private var timer: Timer?
    private var stopped = false
    static func uuid(_ key: Data) -> UUID {
        precondition(key.count == 32)
        var b = Array(HMAC<SHA256>.authenticationCode(for: Data("DroidMirror presence beacon v1".utf8), using: SymmetricKey(data: key)).prefix(16))
        b[6] = (b[6] & 15) | 0x80; b[8] = (b[8] & 63) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    override init() {
        super.init()
        peripheral = CBPeripheralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() {
        stopped = true; timer?.invalidate(); timer = nil
        peripheral.stopAdvertising(); key = nil
    }
    deinit { timer?.invalidate() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { refresh(force: true) }
    private func refresh(force: Bool = false) {
        guard !stopped else { return }
        let next = BLETrust.key()
        guard force || next != key else { return }
        peripheral.stopAdvertising(); key = next
        guard let key, peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: Self.uuid(key))]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { NSLog("DroidMirror beacon: advertising failed: %@", error.localizedDescription) }
    }
}
