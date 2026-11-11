import Foundation

// Shared by the clipboard sender, bulk codec and transfer race (and their standalone tests).
struct ClipboardFilePolicy {
    static let limit = 5_000_000
    static let chunk = 3072
    static let window = 8
    static let bulkWindow = 32
    static func allowed(_ size: Int) -> Bool { size >= 0 && size < limit }
    static func nameAllowed(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || "/\\:".unicodeScalars.contains($0) }
    }
}

struct ApkInstallPolicy {
    static let limit = 256 * 1024 * 1024
    static func allowed(_ size: Int) -> Bool { size > 0 && size < limit }
    static func nameAllowed(_ name: String) -> Bool { ClipboardFilePolicy.nameAllowed(name) && name.lowercased().hasSuffix(".apk") }
}
