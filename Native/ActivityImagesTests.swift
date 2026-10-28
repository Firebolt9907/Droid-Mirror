import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

@main struct ActivityImagesTests {
    static func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        precondition(condition(), "Deferred image test timed out")
    }
    static func png(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8((i * 31 / 4) % 251); pixels[i+1] = UInt8((i / 8) % 253); pixels[i+2] = UInt8((i * 7 / 4) % 255)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
    static func main() {
        let data = png(width: 96, height: 96)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let client = ActivityImages()
        var calls = [[String: Any]](), finished = false
        var source: [String: Any] = ["id": "one", "version": "v1", "appIcon": "preview", "clockOffsetMs": 30000, "_clockReceivedAt": 1000.0]
        client.request = { command, reply in
            calls.append(command)
            DispatchQueue.main.async {
                if command["type"] as? String == "activityImageManifestRequest" {
                    reply(["success": true, "images": ["appIcon": hash, "progressTrackerIcon": hash]])
                } else {
                    let offset = command["offset"] as! Int
                    if offset == 0 { source["version"] = "v2"; _ = client.observe(source) }
                    let end = min(data.count, offset + 768)
                    reply(["success": true, "asset": hash, "offset": offset, "total": data.count, "data": data.subdata(in: offset..<end).base64EncodedString()])
                }
            }
        }
        client.onUpdate = { event in
            if event["appIcon"] as? String == data.base64EncodedString() {
                precondition(event["version"] as? String == "v2", "Upgrade must preserve the newest action version")
                precondition(event["progressTrackerIcon"] as? String == event["appIcon"] as? String)
                precondition(event["_clockReceivedAt"] as? Double == 1000)
                finished = true
            }
        }
        precondition(client.observe(source)["appIcon"] as? String == "preview")
        precondition(calls.isEmpty, "Text/controls render before optional image requests")
        spin { finished }
        precondition(client.transferredBytes == data.count, "Shared content hashes download once")
        let count = calls.count
        source["version"] = "v3"
        precondition(client.observe(source)["appIcon"] as? String == data.base64EncodedString())
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(calls.count == count, "Timer/action updates cannot redownload unchanged artwork")
        client.remove("one"); precondition(client.rendered("one") == nil)

        let stale = ActivityImages()
        var deferred: (([String: Any]?) -> Void)?
        stale.request = { _, reply in deferred = reply }
        stale.onUpdate = { _ in preconditionFailure("Removed activity received an upgrade") }
        _ = stale.observe(source); spin { deferred != nil }
        stale.remove("one"); deferred?(["success": true, "images": ["appIcon": hash]])
        precondition(stale.rendered("one") == nil)

        let revision = ActivityImages()
        var manifestCalls = 0
        var revised = source
        revised["activityImageRevision"] = "image-one"
        revision.request = { command, reply in
            manifestCalls += 1
            precondition(command["imageRevision"] as? String == "image-one")
            DispatchQueue.main.async {
                if manifestCalls == 1 { reply(["success": false, "stale": true]) }
                else { reply(["success": true, "imageRevision": "image-one", "images": [String: String]()]) }
            }
        }
        _ = revision.observe(revised); spin { manifestCalls == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(manifestCalls == 1, "Stale revisions must not spin on BLE")
        revised["version"] = "new-version"
        _ = revision.observe(revised); spin { manifestCalls == 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(manifestCalls == 2)

        let corrupt = ActivityImages()
        var chunks = 0
        corrupt.request = { command, reply in DispatchQueue.main.async {
            if command["type"] as? String == "activityImageManifestRequest" { reply(["success": true, "images": ["appIcon": hash]]) }
            else { chunks += 1; reply(["success": true, "asset": hash, "offset": 999, "total": data.count, "data": "AA=="]) }
        } }
        _ = corrupt.observe(source); spin { chunks == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(corrupt.rendered("one")?["appIcon"] as? String == "preview" && chunks == 1)
        precondition(!ActivityImages.validField("customNodes/24/image") && !ActivityImages.validField("title"))
        let bounded = ActivityImages()
        let fields = ["appIcon", "activityIcon", "contactImage", "contentImage", "progressStartIcon", "progressEndIcon", "progressTrackerIcon"] + (0..<24).map { "customNodes/\($0)/image" }
        var payloads = [String: Data](), maps = [String: [String: String]]()
        for group in 0..<5 {
            var map = [String: String]()
            for (index, field) in fields.enumerated() {
                let pixels = png(width: group*31+index+1, height: 1)
                let key = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
                payloads[key] = pixels; map[field] = key
            }
            maps["many\(group)"] = map
        }
        var boundedChunks = 0
        var last = [String: [String: Any]]()
        bounded.onUpdate = { last[$0["id"] as! String] = $0 }
        bounded.request = { command, reply in DispatchQueue.main.async {
            let id = command["id"] as! String
            if command["type"] as? String == "activityImageManifestRequest" { reply(["success": true, "images": maps[id]!]) }
            else {
                let key = command["asset"] as! String, bytes = payloads[key]!, offset = command["offset"] as! Int
                boundedChunks += 1
                reply(["success": true, "asset": key, "offset": offset, "total": bytes.count,
                       "data": bytes.subdata(in: offset..<min(bytes.count,offset+768)).base64EncodedString()])
            }
        } }
        for group in 0..<5 {
            var entry: [String: Any] = ["id": "many\(group)", "version": "v1", "customNodes": Array(repeating: ["image": "preview"], count: 24)]
            for field in fields where !field.contains("/") { entry[field] = "preview" }
            _ = bounded.observe(entry)
        }
        spin { bounded.cachedAssetCount == 128 && boundedChunks >= 155 }
        let boundedCalls = boundedChunks
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(bounded.cachedAssetCount == 128 && boundedChunks == boundedCalls, "Cache eviction must not cause endless redownloads")
        let first = last["many0"]!
        let previews = fields.filter { field in
            if !field.contains("/") { return first[field] as? String == "preview" }
            let index = Int(field.split(separator: "/")[1])!
            return (first["customNodes"] as! [[String: String]])[index]["image"] == "preview"
        }
        precondition(!previews.isEmpty, "Eviction must release rendered high-resolution data too")
        print("PASS: progressive artwork after content, chunk assembly, shared-cache dedup, timer/version preservation, removal and malformed-chunk fallback")
    }
}
