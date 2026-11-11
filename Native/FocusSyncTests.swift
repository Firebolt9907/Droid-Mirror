import Foundation

@main struct FocusSyncTests {
    static func main() {
        var gate = FocusEchoGate()
        precondition(gate.observe(false, now: 0), "first known state must sync")
        precondition(!gate.observe(false, now: 1), "unchanged state must not resend")
        gate.expect(true, now: 2)
        precondition(!gate.observe(false, now: 3), "suppress old state while Shortcut runs")
        precondition(!gate.observe(true, now: 4), "consume Shortcut echo")
        precondition(gate.observe(false, now: 5), "later local change must sync")
        gate.expect(true, now: 6)
        precondition(!gate.observe(false, now: 22), "failed Shortcut must not invent a change")
        precondition(gate.observe(true, now: 23), "suppression is bounded")
        gate.reset()
        precondition(gate.observe(true, now: 24), "reconnect must publish baseline")
        var phone = FocusPhoneGate()
        precondition(phone.shouldApply(false, origin: nil, localOrigin: nil), "missing origins are not an echo")
        precondition(!phone.shouldApply(false, origin: "phone", localOrigin: "mac"), "duplicate phone sample")
        precondition(!phone.shouldApply(true, origin: "mac", localOrigin: "mac"), "own origin must not run Shortcut")
        precondition(!phone.shouldApply(true, origin: "phone", localOrigin: "mac"), "echo updates baseline")
        precondition(phone.shouldApply(false, origin: "phone", localOrigin: "mac"), "independent phone change")
        phone.reset()
        precondition(phone.shouldApply(false, origin: "phone", localOrigin: "mac"), "reconnect reapplies phone baseline")
        print("Focus sync policy tests passed")
    }
}
