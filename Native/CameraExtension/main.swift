import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:]); result.manufacturer = "DroidMirror"; return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
}
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:]); result.model = "Phone Camera"; return result
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
final class CameraSource: NSObject, CMIOExtensionStreamSource, NSXPCListenerDelegate, CameraExtensionIPC {
    private let providerSource = CameraProviderSource()
    private let deviceSource = CameraDeviceSource()
    let queue = DispatchQueue(label: "app.droidmirror.camera.extension")
    var provider: CMIOExtensionProvider!
    var device: CMIOExtensionDevice!
    var stream: CMIOExtensionStream!
    var formats = [CMIOExtensionStreamFormat]()
    private let listener = NSXPCListener.anonymous()
    private var connection: NSXPCConnection?
    private var clients = 0
    private var published = false
    private var lastPresence = ProcessInfo.processInfo.systemUptime
    private var watchdog: DispatchSourceTimer!
    private var framePump: DispatchSourceTimer!
    private var latestPixel: CVPixelBuffer?
    private var blankPixel: CVPixelBuffer?
    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: providerSource, clientQueue: queue)
        device = CMIOExtensionDevice(localizedName: "DroidMirror Phone Camera", deviceID: UUID(uuidString: "5D9174A0-2B8C-4E96-82E5-C5D1522AFBA1")!, legacyDeviceID: nil, source: deviceSource)
        stream = CMIOExtensionStream(localizedName: "Phone Camera", streamID: UUID(uuidString: "5D9174A0-2B8C-4E96-82E5-C5D1522AFBA2")!, direction: .source, clockType: .hostTime, source: self)
        // A stable output format lets clients stay connected across phone settings changes.
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: 1280, height: 720, extensions: nil, formatDescriptionOut: &description)
        formats = [CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: CMTime(value: 1, timescale: 30), minFrameDuration: CMTime(value: 1, timescale: 30), validFrameDurations: nil)]
        try! device.addStream(stream)
        listener.delegate = self
        listener.resume()
        if let url = CameraIPC.endpointURL, let data = try? NSKeyedArchiver.archivedData(withRootObject: listener.endpoint, requiringSecureCoding: true) {
            try? data.write(to: url, options: .atomic)
        }
        watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self, ProcessInfo.processInfo.systemUptime - self.lastPresence > 4 else { return }
            self.removeDevice()
        }
        watchdog.resume()
        CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &blankPixel)
        if let blankPixel {
            CVPixelBufferLockBaseAddress(blankPixel, [])
            memset(CVPixelBufferGetBaseAddress(blankPixel), 0, CVPixelBufferGetDataSize(blankPixel))
            CVPixelBufferUnlockBaseAddress(blankPixel, [])
        }
        framePump = DispatchSource.makeTimerSource(queue: queue)
        framePump.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333))
        framePump.setEventHandler { [weak self] in self?.emitFrame() }
        framePump.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection incoming: NSXPCConnection) -> Bool {
        // The group entitlement protects endpoint discovery. Pin the signing team and
        // receiver identity too; a process with a copied endpoint cannot inject video.
        guard let requirement = CameraIPC.requirement(for: "app.droidmirror.notifications") else { return false }
        incoming.setCodeSigningRequirement(requirement)
        incoming.invalidationHandler = { [weak self, weak incoming] in
            guard let self else { return }
            self.queue.async { [weak self, weak incoming] in
                guard let self, let incoming, self.connection === incoming else { return }
                self.removeDevice(); self.connection = nil
            }
        }
        incoming.exportedInterface = NSXPCInterface(with: CameraExtensionIPC.self)
        incoming.exportedObject = self
        queue.async {
            self.connection?.invalidate(); self.connection = incoming
        }
        incoming.resume()
        return true
    }
    func updatePresence(_ connected: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.lastPresence = ProcessInfo.processInfo.systemUptime
            if connected && !self.published {
                do { try self.provider.addDevice(self.device); self.published = true }
                catch { NSLog("Camera add device: %@", String(describing: error)) }
            } else if !connected { self.removeDevice() }
            reply(self.published && self.clients > 0)
        }
    }
    private func removeDevice() {
        if published { try? provider.removeDevice(device) }
        published = false; clients = 0; latestPixel = nil
    }
    func submitFrame(_ bytes: Data, width: Int, height: Int, reply: @escaping () -> Void) {
        queue.async {
            defer { reply() }
            guard self.published, self.clients > 0, width == 1280, height == 720, bytes.count == width * height * 4 else { return }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { return }
            CVPixelBufferLockBaseAddress(pixel, [])
            bytes.withUnsafeBytes { source in
                for row in 0..<height {
                    memcpy(CVPixelBufferGetBaseAddress(pixel)!.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)), source.baseAddress!.advanced(by: row * width * 4), width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            self.latestPixel = pixel
        }
    }
    func clearFrame() { queue.async { self.latestPixel = nil } }
    private func emitFrame() {
        guard published, clients > 0, let pixel = latestPixel ?? blankPixel else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: formats[0].formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample {
            stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(CMTimeGetSeconds(now) * 1_000_000_000))
        }
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        result.activeFormatIndex = 0
        result.frameDuration = CMTime(value: 1, timescale: 30)
        return result
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { published }
    func startStream() throws { clients += 1 }
    func stopStream() throws { clients = max(0, clients - 1); if clients == 0 { latestPixel = nil } }
}
let source = CameraSource()
CMIOExtensionProvider.startService(provider: source.provider)
dispatchMain()
