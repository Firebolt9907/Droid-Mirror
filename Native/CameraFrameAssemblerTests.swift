import Foundation

@main enum CameraFrameAssemblerTests {
    static func main() {
        var assembler = CameraFrameAssembler()
        let chunk = Data(repeating: 7, count: 2048)
        assert(assembler.append(frame: 1, chunk: 0, data: chunk, last: false, now: 0) == nil)
        assert(assembler.append(frame: 1, chunk: 1, data: Data([8]), last: true, now: 1) == chunk + Data([8]))
        // Missing, repeated, oversized, and timed-out chunks cannot reach the decoder.
        assert(assembler.append(frame: 2, chunk: 1, data: chunk, last: true, now: 2) == nil)
        assert(assembler.append(frame: 2, chunk: 0, data: chunk, last: false, now: 2) == nil)
        assert(assembler.append(frame: 2, chunk: 2, data: chunk, last: true, now: 2) == nil)
        assert(assembler.append(frame: 3, chunk: 0, data: chunk, last: false, now: 3) == nil)
        assert(assembler.append(frame: 3, chunk: 1, data: chunk, last: true, now: 6) == nil)
        assert(assembler.append(frame: 4, chunk: 0, data: Data(count: 2049), last: true, now: 6) == nil)
        for index in 0..<64 { assert(assembler.append(frame: 5, chunk: index, data: chunk, last: false, now: 7) == nil) }
        assert(assembler.append(frame: 5, chunk: 64, data: Data([0]), last: true, now: 7) == nil)
        assert(assembler.append(frame: 6, chunk: 0, data: Data([1]), last: true, now: 8) == Data([1]))
        assembler.reset()
        assert(assembler.append(frame: 6, chunk: 1, data: chunk, last: true, now: 8) == nil)
        print("Camera frame assembly tests passed")
    }
}
