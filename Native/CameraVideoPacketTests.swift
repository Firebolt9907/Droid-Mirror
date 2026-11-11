import Foundation

@main enum CameraVideoPacketTests {
    static func rejected(_ body: () throws -> Void) {
        do { try body() } catch { return }
        fatalError("Accepted invalid/replayed packet")
    }
    static func main() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let packet = try CameraVideoPacket(fixture)
        assert(packet.epoch == 7 && packet.sequence == 1 && packet.ptsMicroseconds == 123456 && packet.keyframe)
        assert(packet.payload == Data([0, 0, 0, 1, 0x65, 0xff]))
        var order = CameraVideoSequence()
        try order.consume(packet)
        rejected { try order.consume(packet) }
        var gap = fixture; gap[19] = 3
        rejected { try order.consume(CameraVideoPacket(gap)) }
        var next = fixture; next[19] = 2
        try order.consume(CameraVideoPacket(next))
        for offset in [0, 7, 28, 35] {
            var corrupt = fixture; corrupt[offset] = 0xff
            rejected { _ = try CameraVideoPacket(corrupt) }
        }
        rejected { _ = try CameraVideoPacket(fixture.dropLast()) }
        rejected { _ = try CameraVideoPacket(fixture + Data([0])) }
        var zeroEpoch = fixture; zeroEpoch[11] = 0
        rejected { _ = try CameraVideoPacket(zeroEpoch) }
        var epochs = CameraVideoEpoch()
        assert(epochs.accept(epoch: 1, keyframe: true)) // BLE
        assert(!epochs.accept(epoch: 2, keyframe: false)) // Wi-Fi must begin with a keyframe.
        assert(!epochs.accept(epoch: 1, keyframe: true)) // Late BLE frame.
        assert(epochs.accept(epoch: 2, keyframe: true))
        assert(epochs.accept(epoch: 2, keyframe: false))
        epochs.requireKeyframe() // Decoder overload/corruption cannot display dependent frames.
        assert(!epochs.accept(epoch: 2, keyframe: false))
        assert(epochs.accept(epoch: 2, keyframe: true))
        assert(epochs.accept(epoch: 3, keyframe: true)) // Return to BLE.
        assert(!epochs.accept(epoch: 2, keyframe: true)) // Queued Wi-Fi frame cannot restore old picture.
        print("Camera Java/Swift binary compatibility, replay, bounds and handoff tests passed")
    }
}
