import AppKit
import VideoToolbox
import CoreImage

/// Runs in the persistent BLE receiver, independently of every mirror session.
final class ContinuityCamera {
    weak var controller: BLEController?
    private var lane: CameraIrohChannel?
    private var retryAfter: TimeInterval = 0
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var connected = false
    private var polling = false
    private var generation = UUID()
    private var startPayload: [String: Any]?
    private var phoneStarted = false
    private var session: String?
    private var configuration = ""
    private var assembler = CameraFrameAssembler()
    private var videoEpoch = CameraVideoEpoch()
    private var decoderCycle = UUID()
    private var decodingFrames = 0
    private var lastKeyframeRequest: TimeInterval = -.infinity
    private var decoder: VTDecompressionSession?
    private var description: CMVideoFormatDescription?
    private var parameterSets = [Data]()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var rotation = 0
    private var sendingFrame = false

    func connectedToPhone() {
        connected = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    private func attach() {
        guard connection == nil, let url = CameraIPC.endpointURL, let data = try? Data(contentsOf: url),
              let endpoint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSXPCListenerEndpoint.self, from: data) else { return }
        guard let requirement = CameraIPC.requirement(for: CameraIPC.identifier) else { return }
        let candidate = NSXPCConnection(listenerEndpoint: endpoint)
        candidate.setCodeSigningRequirement(requirement)
        candidate.remoteObjectInterface = NSXPCInterface(with: CameraExtensionIPC.self)
        candidate.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.lostExtension() } }
        candidate.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.lostExtension() } }
        candidate.resume(); connection = candidate
    }
    private func lostExtension() {
        connection = nil; polling = false; sendingFrame = false; endCapture()
    }
    private func poll() {
        guard connected else { return }
        attach()
        guard !polling, let connection else { return }
        let epoch = generation
        polling = true
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in DispatchQueue.main.async { self?.lostExtension() } } as? CameraExtensionIPC
        proxy?.updatePresence(true) { [weak self] demanded in DispatchQueue.main.async {
            guard let self, self.generation == epoch, self.connected else { return }
            self.polling = false
            NotificationRuntime.preferences.synchronize()
            let demanded = demanded && NotificationRuntime.host != nil
            let facing = NotificationRuntime.preferences.string(forKey: "DroidMirror.camera.facing") == "back" ? "back" : "front"
            let resolution = 320
            let config = "\(facing):\(resolution)"
            if !demanded || (self.session != nil && self.configuration != config) { self.endCapture() }
            if demanded {
                if self.session == nil && ProcessInfo.processInfo.systemUptime >= self.retryAfter {
                    let id = UUID().uuidString
                    self.session = id; self.configuration = config
                    let command: [String: Any] = ["type": "cameraStart", "session": id, "facing": facing, "width": resolution]
                    self.startPayload = command
                    self.controller?.sendCamera(command)
                } else if let command = self.startPayload, !self.phoneStarted {
                    self.controller?.sendCamera(command)
                } else if let id = self.session {
                    self.controller?.sendCamera(["type": "cameraLease", "session": id])
                }
            }
        } }
    }
    func stop() {
        connected = false; generation = UUID(); timer?.invalidate(); timer = nil
        endCapture()
        (connection?.remoteObjectProxy as? CameraExtensionIPC)?.updatePresence(false) { _ in }
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil
        connection?.invalidate(); connection = nil; polling = false; sendingFrame = false
    }
    private func endCapture() {
        (connection?.remoteObjectProxy as? CameraExtensionIPC)?.clearFrame()
        if let session { controller?.sendCamera(["type": "cameraStop", "session": session]) }
        lane?.close(); lane = nil
        session = nil; startPayload = nil; phoneStarted = false; assembler.reset()
        resetDecoder(); videoEpoch = CameraVideoEpoch()
    }
    private func resetDecoder() {
        decoderCycle = UUID(); decodingFrames = 0
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; description = nil; parameterSets = []
    }
    private func observeEpoch(_ epoch: UInt32) -> Bool {
        guard epoch > 0, epoch >= videoEpoch.current else { return false }
        if epoch > videoEpoch.current {
            resetDecoder(); assembler.reset()
            _ = videoEpoch.accept(epoch: epoch, keyframe: false)
            (connection?.remoteObjectProxy as? CameraExtensionIPC)?.clearFrame()
        }
        return true
    }
    private func requestKeyframe() {
        resetDecoder()
        videoEpoch.requireKeyframe()
        let now = ProcessInfo.processInfo.systemUptime
        guard let session, now - lastKeyframeRequest > 0.5 else { return }
        lastKeyframeRequest = now
        controller?.sendCamera(["type": "cameraKeyframe", "session": session, "epoch": Int(videoEpoch.current)])
    }
    private func receiveVideo(_ packet: CameraVideoPacket) {
        guard session != nil, observeEpoch(packet.epoch), videoEpoch.accept(epoch: packet.epoch, keyframe: packet.keyframe) else { return }
        decode(packet.payload)
    }
    func receive(_ event: [String: Any]) {
        guard let session, event["session"] as? String == session else { return }
        if event["type"] as? String == "cameraIrohOffer" {
            guard lane == nil, event["videoVersion"] as? Int == 2, let key = BLETrust.key(), let token = event["token"] as? String,
                  token.count == 64, let addresses = event["addresses"] as? [String], addresses.count <= 32 else { return }
            let channel = CameraIrohChannel(); lane = channel
            channel.connect(key: key, token: token, session: session, addresses: addresses, receive: { [weak self, weak channel] packet in
                guard let self, self.session == session, self.lane === channel else { return }
                self.receiveVideo(packet)
            }, failed: { [weak self, weak channel] in
                guard let self, self.session == session, self.lane === channel else { return }
                self.lane = nil
            })
            return
        }
        if event["type"] as? String == "cameraState" {
            rotation = event["rotation"] as? Int ?? 0
            phoneStarted = event["error"] == nil
            if let error = event["error"] as? String {
                NSLog("DroidMirror camera: %@", error)
                endCapture(); retryAfter = ProcessInfo.processInfo.systemUptime + 5
            }
            return
        }
        guard event["type"] as? String == "cameraFrame", let id = event["frame"] as? Int,
              let chunk = event["chunk"] as? Int, let encoded = event["data"] as? String,
              let data = Data(base64Encoded: encoded), data.count <= 2048,
              let rawEpoch = event["epoch"] as? Int, rawEpoch > 0, rawEpoch <= Int(UInt32.max),
              observeEpoch(UInt32(rawEpoch)) else { return }
        if let frame = assembler.append(frame: id, chunk: chunk, data: data,
                                        last: event["last"] as? Bool == true,
                                        now: ProcessInfo.processInfo.systemUptime) {
            if videoEpoch.accept(epoch: UInt32(rawEpoch), keyframe: true) { decode(frame) }
            controller?.sendCamera(["type": "cameraFrameAck", "session": session, "frame": id, "epoch": rawEpoch])
        }
    }

    private func decode(_ annexB: Data) {
        guard decodingFrames < 3 else { requestKeyframe(); return }
        let bytes = [UInt8](annexB)
        var starts = [(Int, Int)](), i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var nals = [Data]()
        for index in starts.indices {
            let start = starts[index].0 + starts[index].1
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            if start < end { nals.append(Data(bytes[start..<end])) }
        }
        let sets = [7, 8].compactMap { type in nals.first { Int($0[0] & 31) == type } }
        if sets.count == 2 && sets != parameterSets {
            if let decoder { VTDecompressionSessionInvalidate(decoder) }; decoder = nil
            parameterSets = sets
            sets[0].withUnsafeBytes { sps in sets[1].withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sets[0].count, sets[1].count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            } }
        }
        guard let description else { return }
        if decoder == nil {
            VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
        }
        guard let decoder else { return }
        var avcc = Data()
        for nal in nals where ![7, 8].contains(Int(nal[0] & 31)) {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }; avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?, size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let epoch = generation, capture = session, cycle = decoderCycle
        decodingFrames += 1
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, pixel, _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == epoch, self.session == capture, self.session != nil, self.decoderCycle == cycle else { return }
                self.decodingFrames = max(0, self.decodingFrames - 1)
                guard status == noErr, let pixel else { self.requestKeyframe(); return }
                self.submit(pixel)
            }
        }
        if status != noErr { requestKeyframe() }
    }
    private func submit(_ pixel: CVPixelBuffer) {
        guard !sendingFrame, let proxy = connection?.remoteObjectProxy as? CameraExtensionIPC else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == kCVReturnSuccess, let output else { return }
        var image = CIImage(cvPixelBuffer: pixel)
        switch rotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        let scale = min(1280 / image.extent.width, 720 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(translationX: (1280 - scaled.extent.width) / 2 - scaled.extent.minX,
                                                               y: (720 - scaled.extent.height) / 2 - scaled.extent.minY))
        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        imageContext.render(centered.composited(over: background), to: output)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        var bytes = Data(count: 1280 * 720 * 4)
        bytes.withUnsafeMutableBytes { destination in
            for row in 0..<720 { memcpy(destination.baseAddress!.advanced(by: row * 5120), CVPixelBufferGetBaseAddress(output)!.advanced(by: row * CVPixelBufferGetBytesPerRow(output)), 5120) }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        sendingFrame = true
        proxy.submitFrame(bytes, width: 1280, height: 720) { [weak self] in DispatchQueue.main.async { self?.sendingFrame = false } }
    }
}
