import Foundation

struct CameraVideoPacket {
    static let headerBytes = 36
    static let maximumPayload = 2 * 1024 * 1024
    let epoch: UInt32
    let sequence: UInt64
    let ptsMicroseconds: UInt64
    let keyframe: Bool
    let payload: Data
    enum Failure: Error { case invalid }
    init(_ bytes: Data) throws {
        guard bytes.count >= Self.headerBytes, bytes.prefix(8) == Data("DMCV0001".utf8) else { throw Failure.invalid }
        func number(_ offset: Int, _ length: Int) -> UInt64 {
            bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let epoch = number(8, 4), sequence = number(12, 8), pts = number(20, 8)
        let flags = number(28, 4), size = number(32, 4)
        guard epoch > 0, sequence > 0, sequence <= UInt64(Int64.max), pts <= UInt64(Int64.max), flags <= 1,
              size > 0, size <= Self.maximumPayload, bytes.count == Self.headerBytes + Int(size) else { throw Failure.invalid }
        self.epoch = UInt32(epoch); self.sequence = sequence; ptsMicroseconds = pts
        keyframe = flags == 1; payload = bytes.subdata(in: Self.headerBytes..<bytes.count)
    }
}

/// Older transport epochs and dependent frames after a reset never reach VideoToolbox.
struct CameraVideoEpoch {
    private(set) var current: UInt32 = 0
    private var waitingForKeyframe = true
    mutating func requireKeyframe() { waitingForKeyframe = true }
    mutating func accept(epoch: UInt32, keyframe: Bool) -> Bool {
        guard epoch > 0, epoch >= current else { return false }
        if epoch > current { current = epoch; waitingForKeyframe = true }
        guard !waitingForKeyframe || keyframe else { return false }
        waitingForKeyframe = false
        return true
    }
}

struct CameraVideoSequence {
    private var next: UInt64 = 1
    mutating func consume(_ packet: CameraVideoPacket) throws {
        guard packet.sequence == next else { throw CameraVideoPacket.Failure.invalid }
        next += 1
    }
}
