import Foundation

@main
struct MirrorMinimizeRoutingTests {
    static func main() {
        var target = MirrorWindowCommandTarget()
        let start = Date(timeIntervalSince1970: 100)
        precondition(target.target(now: start) == nil)
        target.session(pid: -1, active: true, now: start)
        target.session(pid: 0, active: true, now: start)
        target.session(pid: Int.max, active: true, now: start)
        precondition(target.target(now: start) == nil)
        target.session(pid: 1234, active: true, now: start)
        precondition(target.target(now: start.addingTimeInterval(1)) == 1234)
        // A repeated tap targets the same current mirror, even if LaunchServices has PID -1.
        precondition(target.target(now: start.addingTimeInterval(2)) == 1234)
        target.session(pid: 5678, active: false, now: start)
        precondition(target.target(now: start) == 1234)
        precondition(target.target(now: start.addingTimeInterval(4)) == nil)
        target.session(pid: 5678, active: true, now: start.addingTimeInterval(4))
        precondition(target.target(now: start.addingTimeInterval(5)) == 5678)
        target.session(pid: 1234, active: false, now: start.addingTimeInterval(5))
        precondition(target.target(now: start.addingTimeInterval(5)) == 5678)
        target.session(pid: 5678, active: false, now: start.addingTimeInterval(5))
        precondition(target.target(now: start.addingTimeInterval(5)) == nil)
        print("PASS: minimize routing uses current session heartbeat, rejects invalid/stale PIDs, survives repeated taps and session changes")
    }
}
