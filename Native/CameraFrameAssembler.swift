import Foundation

/// One bounded Annex-B access unit. A new first chunk supersedes an incomplete frame.
struct CameraFrameAssembler {
    private var bytes = Data()
    private var frame = -1
    private var nextChunk = 0
    private var started: TimeInterval = 0
    mutating func reset() { self = CameraFrameAssembler() }
    mutating func append(frame: Int, chunk: Int, data: Data, last: Bool, now: TimeInterval) -> Data? {
        guard frame >= 0, chunk >= 0, data.count <= 2048 else { reset(); return nil }
        if chunk == 0 { self.frame = frame; nextChunk = 0; bytes.removeAll(keepingCapacity: true); started = now }
        guard self.frame == frame, chunk == nextChunk, bytes.count + data.count <= 131072,
              now >= started, now - started < 3 else { reset(); return nil }
        bytes.append(data); nextChunk += 1
        if last { let result = bytes; reset(); return result }
        return nil
    }
}
