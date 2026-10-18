import Foundation

@main
struct PhoneUsePolicyTests {
    static func main() {
        let awake = "Power Manager State:\n  mWakefulness=Awake"
        let locked = "KeyguardServiceDelegate\n  showing=true\n  secure=true\n  enabled=true"
        let unlocked = "KeyguardServiceDelegate\n  showing=false\n  secure=true\n  enabled=true"
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: unlocked) == true)
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: locked) == false)
        for state in ["Asleep", "Dozing"] {
            precondition(PhoneUsePolicy.isInUse(power: "mWakefulness=\(state)", windowPolicy: unlocked) == false)
        }
        precondition(PhoneUsePolicy.isInUse(power: "mInteractive=true", windowPolicy: "mShowingLockscreen=false") == true)
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: "isKeyguardShowing=true") == false)
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: "isKeyguardShowing=false") == true)
        // Unknown/failed dumps must not authorize taking over a phone.
        precondition(PhoneUsePolicy.isInUse(power: "Permission denied", windowPolicy: unlocked) == nil)
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: "Permission denied") == nil)
        precondition(PhoneUsePolicy.isInUse(power: awake, windowPolicy: "KeyguardServiceDelegate\n  inputRestricted=false") == nil)
        print("PASS: active phones blocked; locked, asleep and dozing phones available; unknown state rejected")
    }
}
