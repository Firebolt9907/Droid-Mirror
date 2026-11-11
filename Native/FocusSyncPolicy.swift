import Foundation

/// A remote change is consumed as a baseline, never reflected back to its origin.
struct FocusEchoGate {
    private(set) var last: Bool?
    private var expected: Bool?
    private var until: TimeInterval = 0
    mutating func expect(_ value: Bool, now: TimeInterval) { expected = value; until = now + 15 }
    mutating func observe(_ value: Bool, now: TimeInterval) -> Bool {
        defer { last = value }
        if let expected, now < until {
            if value == expected { self.expected = nil }
            return false
        }
        expected = nil
        return last != value
    }
    mutating func reset() { self = FocusEchoGate() }
}

/// Deduplicate phone snapshots, including echoes, without mistaking two nil origins for an echo.
struct FocusPhoneGate {
    private var last: Bool?
    mutating func shouldApply(_ focused: Bool, origin: String?, localOrigin: String?) -> Bool {
        defer { last = focused }
        let ownEcho = localOrigin.map { origin == $0 } ?? false
        return last != focused && !ownEcho
    }
    mutating func reset() { self = FocusPhoneGate() }
}
