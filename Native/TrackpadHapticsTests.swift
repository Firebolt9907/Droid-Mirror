import Foundation

@main
struct TrackpadHapticsTests {
    static func main() {
        if CommandLine.arguments.contains("--live") {
            let success = PrivateTrackpadActuator().tick()
            print("Private strong actuation: \(success ? "success" : "unavailable")")
            exit(success ? 0 : 1)
        }
        var attempts = 0, publicTicks = 0
        var available = true
        let feedback = TrackpadHaptics(performPrivate: {
            attempts += 1
            return available
        }, performPublic: { publicTicks += 1 })
        feedback.tick()
        precondition(attempts == 1 && publicTicks == 0, "Successful private feedback must not double-play")
        available = false
        feedback.tick()
        precondition(attempts == 2 && publicTicks == 1, "Private failure must play the public fallback")
        available = true
        feedback.tick()
        precondition(attempts == 3 && publicTicks == 1, "A recovered device must use private feedback again")
        print("PASS: private tick selection, public fallback, no double playback and recovery")
    }
}
