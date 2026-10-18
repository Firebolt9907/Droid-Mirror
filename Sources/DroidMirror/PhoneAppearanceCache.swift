import Foundation

/// Use the transport's device identifier, never a shared last-phone cache.
enum PhoneAppearanceCache {
    static func path(for device: AndroidDevice) -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMirror/PhoneAppearance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = device.id.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json").path
    }
}

import AppKit
import SwiftUI

struct PhoneAppearanceSnapshot {
    var wallpaper: NSImage?
    var name: String?
    var topRatio = 0.0
    var bottomRatio = 0.0

    init(device: AndroidDevice?) {
        guard let device, let data = FileManager.default.contents(atPath: PhoneAppearanceCache.path(for: device)),
              data.count <= 65_536, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        name = value["deviceName"]
        wallpaper = value["wallpaper"].flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) }
        guard let dump = value["displayDump"] else { return }
        for line in dump.components(separatedBy: .newlines) where line.contains("DisplayDeviceInfo{") && line.contains("type INTERNAL") {
            func number(_ pattern: String) -> Double? {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { return nil }
                return Double(line[range])
            }
            guard let width = number(#",\s*(\d+) x \d+,"#), width >= 100, width <= 20_000,
                  let top = number(#"position=TopLeft, radius=(\d+)"#),
                  let bottom = number(#"position=BottomLeft, radius=(\d+)"#),
                  top < width / 2, bottom < width / 2 else { continue }
            topRatio = top / width
            bottomRatio = bottom / width
            break
        }
    }
}

/// The fallback uses the same normalized exponent-3 silhouette as the renderer.
struct PhoneScreenShape: Shape {
    var topRatio: Double
    var bottomRatio: Double
    func path(in rect: CGRect) -> Path {
        let conversion = 0.92 * (1 - sqrt(0.5)) / (1 - pow(0.5, 1.0 / 3))
        let top = min(rect.width * topRatio * conversion, min(rect.width, rect.height) / 2)
        let bottom = min(rect.width * bottomRatio * conversion, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        for corner in 0..<4 {
            let extent = (corner == 0 || corner == 3) ? top : bottom
            // Traverse top-right, bottom-right, bottom-left, top-left in SwiftUI coordinates.
            for step in 0...128 {
                let angle = Double(step) / 128 * .pi / 2
                let x = extent * (1 - pow(cos(angle), 2.0 / 3))
                let y = extent * (1 - pow(sin(angle), 2.0 / 3))
                let point: CGPoint
                switch corner {
                case 0: point = CGPoint(x: rect.maxX - y, y: rect.minY + x)
                case 1: point = CGPoint(x: rect.maxX - x, y: rect.maxY - y)
                case 2: point = CGPoint(x: rect.minX + y, y: rect.maxY - x)
                default: point = CGPoint(x: rect.minX + x, y: rect.minY + y)
                }
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
