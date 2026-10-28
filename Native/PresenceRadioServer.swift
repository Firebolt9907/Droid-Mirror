import Foundation
import CoreBluetooth
import CryptoKit
import IOBluetooth

/// Presence-only endpoints. They never execute commands or change mirror authentication.
/// Each active probe supplies a fresh 16-byte nonce; proofs are transport-domain separated.
final class PresenceRadioServer: NSObject, CBPeripheralManagerDelegate, IOBluetoothRFCOMMChannelDelegate {
    private var peripheral: CBPeripheralManager!
    private var key: Data?
    private var serviceID: CBUUID?
    private var record: IOBluetoothSDPServiceRecord?
    private var registration: IOBluetoothUserNotification?
    private var requests = [UUID: (Data, TimeInterval)]()
    private var channels = [IOBluetoothRFCOMMChannel]()
    private var buffers = [ObjectIdentifier: Data]()
    private var timer: Timer?
    private var stopped = false
    private var classicAttempts = 0
    // SDP's NSNumber shorthand is uint32; RFCOMM requires an explicit uint8.
    static let channelElement: [String: Any] = ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": 0]
    static let characteristic = CBUUID(string: "7E57B102-9A6B-4C5D-8E7F-102030405060")
    static func uuid(_ key: Data, _ label: String) -> UUID {
        var b = Array(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: key)).prefix(16))
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
        peripheral.stopAdvertising(); peripheral.removeAllServices()
        registration?.unregister(); registration = nil
        record?.remove(); record = nil
        for channel in channels { channel.close() }
        channels.removeAll(); buffers.removeAll(); requests.removeAll(); key = nil
    }
    deinit { timer?.invalidate() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { refresh(force: true) }
    private func refresh(force: Bool = false) {
        guard !stopped else { return }
        let next = BLETrust.key()
        if !force && next == key {
            if let key, record == nil, classicAttempts < 6, peripheral.state == .poweredOn { publishClassic(key) }
            return
        }
        classicAttempts = 0
        peripheral.stopAdvertising(); peripheral.removeAllServices()
        registration?.unregister(); registration = nil; record?.remove(); record = nil
        for channel in channels { channel.close() }
        channels.removeAll(); buffers.removeAll(); requests.removeAll()
        key = next
        guard let key else { return }
        if peripheral.state == .poweredOn {
            let id = CBUUID(nsuuid: Self.uuid(key, "DroidMirror presence beacon v1"))
            serviceID = id
            let service = CBMutableService(type: id, primary: true)
            service.characteristics = [CBMutableCharacteristic(type: Self.characteristic, properties: [.read, .write], value: nil, permissions: [.readable, .writeable])]
            peripheral.add(service)
        }
        publishClassic(key)
    }
    private func publishClassic(_ key: Data) {
        classicAttempts += 1
        var classic = Self.uuid(key, "DroidMirror presence classic v1").uuid
        let classicData = withUnsafeBytes(of: &classic) { Data($0) }
        // Channel zero asks SDP to allocate an available RFCOMM channel.
        let attributes: [String: Any] = [
            "0001 - ServiceClassIDList": [IOBluetoothSDPUUID(data: classicData)],
            "0004 - ProtocolDescriptorList": [
                [IOBluetoothSDPUUID(uuid16: 0x0100)!],
                [IOBluetoothSDPUUID(uuid16: 0x0003)!, Self.channelElement]],
            "0100 - ServiceName": "DroidMirror presence"]
        record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: attributes)
        if record == nil { NSLog("DroidMirror presence: Classic SDP service could not be published") }
        var channel: BluetoothRFCOMMChannelID = 0
        if let record, record.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
            registration = IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
                selector: #selector(opened(_:channel:)), withChannelID: channel, direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
            if registration == nil { record.remove(); self.record = nil }
        } else if let record {
            record.remove(); self.record = nil
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { NSLog("DroidMirror presence: GATT publication failed: %@", error.localizedDescription) }
        guard !stopped, error == nil, service.uuid == serviceID else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { NSLog("DroidMirror presence: advertising failed: %@", error.localizedDescription) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite writes: [CBATTRequest]) {
        guard let first = writes.first else { return }
        guard key != nil, writes.count == 1, first.characteristic.uuid == Self.characteristic,
              first.offset == 0, let value = first.value, value.count == 16 else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
        }
        requests = requests.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < 15 }
        guard requests.count < 16 || requests[first.central.identifier] != nil else {
            peripheral.respond(to: first, withResult: .insufficientResources); return
        }
        requests[first.central.identifier] = (value, ProcessInfo.processInfo.systemUptime)
        peripheral.respond(to: first, withResult: .success)
    }
    static func proof(key: Data, nonce: Data, transport: String) -> Data? {
        guard key.count == 32, nonce.count == 16, ["gatt", "classic"].contains(transport) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("DroidMirror presence \(transport) v1".utf8) + nonce, using: SymmetricKey(data: key)))
    }
    private func proof(_ nonce: Data, _ transport: String) -> Data? {
        guard let key else { return nil }
        return Self.proof(key: key, nonce: nonce, transport: transport)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.characteristic,
              let pending = requests[request.central.identifier],
              ProcessInfo.processInfo.systemUptime - pending.1 < 15,
              let value = proof(pending.0, "gatt"), request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .unlikelyError); return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }
    @objc private func opened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        guard !stopped, key != nil, channels.count < 8 else { channel.close(); return }
        channels.append(channel); buffers[ObjectIdentifier(channel)] = Data()
        channel.setDelegate(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.remove(channel)
        }
    }
    private func remove(_ channel: IOBluetoothRFCOMMChannel) {
        buffers.removeValue(forKey: ObjectIdentifier(channel))
        channels.removeAll { $0 === channel }
        channel.close()
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard let channel else { return }
        buffers.removeValue(forKey: ObjectIdentifier(channel)); channels.removeAll { $0 === channel }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length: Int) {
        guard let channel, let dataPointer, length > 0, var data = buffers[ObjectIdentifier(channel)], data.count + length <= 16 else {
            if let channel { remove(channel) }; return
        }
        data.append(dataPointer.assumingMemoryBound(to: UInt8.self), count: length)
        buffers[ObjectIdentifier(channel)] = data
        guard data.count == 16, var response = proof(data, "classic") else { return }
        buffers.removeValue(forKey: ObjectIdentifier(channel))
        _ = response.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        // Leave closure to the peer/timeout so the response can drain.
    }
}
