import Foundation

enum BrowserURL {
    static func browserURL(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        return url
    }

}
