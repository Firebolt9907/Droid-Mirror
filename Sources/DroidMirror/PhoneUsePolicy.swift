import Foundation

/// An awake, unlocked phone belongs to its local user. A visible lock screen is available.
enum PhoneUsePolicy {
    static let errorMessage = "Phone is in use. Lock your phone, then try mirroring again."

    static func isInUse(power: String, windowPolicy: String) -> Bool? {
        let power = power.lowercased()
        let window = windowPolicy.lowercased()
        func matches(_ pattern: String, _ text: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if matches(#"\bmwakefulness=(asleep|dozing)\b|\bminteractive=false\b"#, power) { return false }
        guard matches(#"\bmwakefulness=awake\b|\bminteractive=true\b"#, power) else { return nil }
        let direct = #"\b(mshowinglockscreen|iskeyguardshowing|isstatusbarkeyguard)="#
        if matches(direct + #"true\b"#, window) { return false }
        if let marker = window.range(of: "keyguardservicedelegate") {
            let block = String(window[marker.upperBound...].prefix(1200))
            if matches(#"(?m)^\s*showing=true\b"#, block) { return false }
            if matches(#"(?m)^\s*showing=false\b"#, block) { return true }
        }
        if matches(direct + #"false\b"#, window) { return true }
        return nil
    }
}
