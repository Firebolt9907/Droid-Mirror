import AppKit
import CoreBluetooth
import CoreImage.CIFilterBuiltins
import IOBluetooth
import SwiftUI

@MainActor
final class QRPairingReceiver: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    @Published var image: NSImage?
    @Published var message = "Starting secure Bluetooth key transfer…"
    private var manager: CBPeripheralManager?
    private var secret = Data()
    private let serviceID = UUID().uuidString.uppercased()
    private var mac = ""
    private var buffer = Data()
    private var acknowledgement: Data?
    private var fragmentDeadline: Date = .distantPast
    private var central: UUID?
    private var deadline: Date = .distantPast
    private var timer: Timer?
    private var saving = false
    private var active = false
    private var save: ((Data) async throws -> Void)?

    func start(save: @escaping (Data) async throws -> Void) {
        guard manager == nil else { return }
        guard let address = IOBluetoothHostController.default()?.addressAsString() else {
            message = "Could not identify this Mac. Use manual code entry."; return
        }
        mac = address.replacingOccurrences(of: "-", with: ":").uppercased()
        secret = Data(count: 32)
        let result = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { message = "Could not start secure pairing."; return }
        self.save = save
        active = true
        deadline = Date().addingTimeInterval(120)
        timer = .scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stop(); self.message = "QR code expired. Close and reopen to try again."
            }
        }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func stop() {
        active = false
        timer?.invalidate(); timer = nil
        manager?.stopAdvertising(); manager?.removeAllServices()
        secret.resetBytes(in: 0..<secret.count); secret.removeAll()
        buffer.removeAll(); acknowledgement = nil; image = nil; save = nil
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard active else { return }
        guard peripheral.state == .poweredOn else {
            if peripheral.state != .unknown && peripheral.state != .resetting {
                stop(); message = "Bluetooth unavailable. Enable Bluetooth and allow DroidMirror access, then reopen this screen."
            }
            return
        }
        let service = CBMutableService(type: CBUUID(string: serviceID), primary: true)
        service.characteristics = [CBMutableCharacteristic(type: CBUUID(string: QRPairingProtocol.characteristic),
            properties: [.write, .read], value: nil, permissions: [.writeable, .readable])]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active else { return }
        guard error == nil else { stop(); message = "Bluetooth pairing service could not start. Use manual code entry."; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: serviceID)]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard active else { return }
        guard error == nil else { stop(); message = "Bluetooth advertising failed. Use manual code entry."; return }
        var url = URLComponents()
        url.scheme = "droidmirror-pair"; url.host = "v1"
        url.queryItems = [URLQueryItem(name: "service", value: serviceID), URLQueryItem(name: "mac", value: mac),
                          URLQueryItem(name: "secret", value: secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))]
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.string!.utf8); filter.correctionLevel = "M"
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
           let cg = CIContext().createCGImage(output, from: output.extent) {
            image = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
        }
        message = "On Android, select this Mac and tap Scan Mac QR code. This code expires in two minutes."
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == CBUUID(string: QRPairingProtocol.characteristic),
              request.central.identifier == central, let acknowledgement, request.offset == 0 else {
            peripheral.respond(to: request, withResult: .readNotPermitted); return
        }
        request.value = acknowledgement
        peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard active, Date() < deadline, !saving else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        if Date() >= fragmentDeadline { buffer.removeAll(); central = nil }
        for request in requests {
            guard request.characteristic.uuid == CBUUID(string: QRPairingProtocol.characteristic),
                  request.offset == 0, let value = request.value, !value.isEmpty, value.count <= 20,
                  (central == nil || central == request.central.identifier), buffer.count + value.count <= 60 else {
                buffer.removeAll(); central = nil
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
            }
            central = request.central.identifier; buffer.append(value)
            fragmentDeadline = Date().addingTimeInterval(5)
        }
        guard buffer.count == 60 else { peripheral.respond(to: first, withResult: .success); return }
        do {
            let key = try QRPairingProtocol.open(buffer, secret: secret, service: serviceID, mac: mac)
            guard let save else { throw CocoaError(.userCancelled) }
            // Consume the invitation before awaiting Keychain. No replay or second delivery is accepted.
            let proof = QRPairingProtocol.acknowledgement(packet: buffer, secret: secret, service: serviceID, mac: mac)
            saving = true; image = nil; peripheral.stopAdvertising()
            timer?.invalidate(); timer = nil
            secret.resetBytes(in: 0..<secret.count); secret.removeAll(); buffer.removeAll()
            Task { [self] in
                do {
                    try await save(key)
                    acknowledgement = proof
                    active = false
                    peripheral.respond(to: first, withResult: .success)
                    message = "Pairing key saved securely. Your existing Android key is unchanged."
                    timer = .scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.stop() }
                    }
                } catch {
                    peripheral.respond(to: first, withResult: .unlikelyError)
                    stop(); message = "Could not save the key. Close and reopen to retry, or use manual entry."
                }
            }
        } catch {
            buffer.removeAll(); central = nil
            peripheral.respond(to: first, withResult: .insufficientAuthentication)
        }
    }
}

struct QRPairingButton: View {
    @EnvironmentObject private var model: MirrorModel
    @State private var showing = false
    var body: some View {
        Button("Pair with QR code…") { showing = true }
            .disabled(model.selectedDevice?.isBluetooth != true || model.isStarting || model.isMirroring || model.isPairingBluetooth)
            .sheet(isPresented: $showing) {
                if let device = model.selectedDevice {
                    QRPairingSheet(device: device, model: model)
                }
            }
    }
}

private struct QRPairingSheet: View {
    let device: AndroidDevice
    @ObservedObject var model: MirrorModel
    @StateObject private var receiver = QRPairingReceiver()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("Pair \(device.displayName)").font(.title2)
            if let image = receiver.image {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 280, height: 280)
                    .padding(16).background(.white)
            }
            Text(receiver.message).multilineTextAlignment(.center)
            Text("Only scan this code with your own phone. Manual code entry still works with older versions.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isSavingQRPairing)
        }
        .padding(24).frame(width: 420)
        .interactiveDismissDisabled(model.isSavingQRPairing)
        .onAppear {
            guard model.beginQRPairing() else { dismiss(); return }
            receiver.start { key in try await model.saveQRPairing(key, address: device.id) }
        }
        .onDisappear { receiver.stop(); model.endQRPairing() }
    }
}
