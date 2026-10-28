import Foundation
import CryptoKit

@main struct SecurityTests {
    static func main() throws {
        let discoveryKey = Data(HMAC<SHA256>.authenticationCode(
            for: Data("DroidMirror notifications pairing v1".utf8),
            using: SymmetricKey(data: Data(0..<32))))
        let discovery = BLEDiscovery.uuid(key: discoveryKey)
        precondition(discovery.uuidString.lowercased() == "78daac5a-2c5f-8f8f-830c-5e1fe3a976da")
        let known = UUID(), stranger = UUID()
        precondition(!BLEDiscovery.permits(stranger, remembered: nil, advertised: [], discovery: discovery))
        precondition(!BLEDiscovery.permits(stranger, remembered: known, advertised: [UUID()], discovery: discovery))
        precondition(BLEDiscovery.permits(known, remembered: known, advertised: [], discovery: discovery))
        // A new privacy identity is selectable only with our pairing-specific advertisement.
        precondition(BLEDiscovery.permits(stranger, remembered: known, advertised: [discovery], discovery: discovery))
        precondition(BLEDiscovery.uuid(key: Data(repeating: 99, count: 32)) != discovery)
        let arguments = CommandLine.arguments
        let task = Process(); task.executableURL = URL(fileURLWithPath: arguments[1])
        task.arguments = ["-cp", arguments[2], "BLESecurityPeer"]
        let input = Pipe(), output = Pipe()
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.standardError
        try task.run()
        func check(_ value: Bool) { precondition(value) }
        func exchange(_ object: [String: Any], wire: Data? = nil) throws -> [String: Any] {
            let packet: Data
            if let wire { packet = wire }
            else { packet = try JSONSerialization.data(withJSONObject: object) }
            try input.fileHandleForWriting.write(contentsOf: packet + Data([10]))
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte.first == 10 { break }; line.append(byte)
            }
            return try JSONSerialization.jsonObject(with: line) as! [String: Any]
        }
        func reject(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection") } catch { }
        }
        let key = Data(HMAC<SHA256>.authenticationCode(for: Data("DroidMirror notifications pairing v1".utf8),
            using: SymmetricKey(data: Data(repeating: 7, count: 32))))
        let nonce = Data(repeating: 11, count: 32)
        let client = try BLESecureSession(key: key, nonce: nonce)
        let challenge = try exchange(client.hello)
        let wrong = try BLESecureSession(key: Data(repeating: 8, count: 32), nonce: nonce)
        reject { _ = try wrong.challenge(challenge) }
        let finish = try client.challenge(challenge)
        reject { _ = try client.challenge(challenge) }
        check(try exchange(["type": "finish", "proof": Data(repeating: 0, count: 32).base64EncodedString()])["rejected"] as? Bool == true)
        let ready = try exchange(finish)
        check(try client.open(ready)["type"] as? String == "ready")
        reject { _ = try client.open(ready) }
        let payload: [String: Any] = ["type": "action", "text": "Diagonal scroll ✓", "request": "test"]
        let sealed = try client.seal(payload)
        let original = try JSONSerialization.jsonObject(with: sealed) as! [String: Any]
        var tampered = original
        var box = Data(base64Encoded: original["box"] as! String)!
        box[box.count - 1] ^= 1; tampered["box"] = box.base64EncodedString()
        check(try exchange(tampered)["rejected"] as? Bool == true)
        let response = try exchange(original)
        var damagedResponse = response
        var damagedBox = Data(base64Encoded: response["box"] as! String)!
        damagedBox[damagedBox.count - 1] ^= 1
        damagedResponse["box"] = damagedBox.base64EncodedString()
        reject { _ = try client.open(damagedResponse) }
        check(try client.open(response)["text"] as? String == payload["text"] as? String)
        check(try exchange(original)["rejected"] as? Bool == true)
        reject { _ = try client.open(response) }
        // Image-heavy notifications must fit after encryption and Base64, not
        // just before encryption. Exercise the actual Android sealing code too.
        let imageEvent: [String: Any] = ["type": "notification", "snapshot": true,
            "appIcon": Data(repeating: 42, count: 2048).base64EncodedString(),
            "contactImage": Data(repeating: 42, count: 1800).base64EncodedString(),
            "body": String(repeating: "x", count: 400)]
        check(try JSONSerialization.data(withJSONObject: imageEvent).count <= 5800)
        let imageSealed = try client.seal(imageEvent)
        check(imageSealed.count <= 8192)
        let imageResponse = try exchange(JSONSerialization.jsonObject(with: imageSealed) as! [String: Any])
        check(try JSONSerialization.data(withJSONObject: imageResponse).count <= 8192)
        check(try client.open(imageResponse)["contactImage"] as? String == imageEvent["contactImage"] as? String)
        var tamperedResponse = response
        tamperedResponse["seq"] = 3
        reject { _ = try client.open(tamperedResponse) }
        let large = Data(repeating: 42, count: 8192)
        for maximum in [20, 182, 512, 514, 517] {
            var assembly = BLEFragments(); var result: Data?
            for frame in BLEFragments.split(large, id: 1, maximum: maximum) {
                precondition(frame.count <= min(512, maximum), "ATT attributes must fit even at MTU 517")
                result = assembly.accept(frame)
            }
            precondition(result == large)
        }
        precondition(BLEFragments.split(Data(repeating: 0, count: 8193), id: 1, maximum: 20).isEmpty)
        var assembly = BLEFragments()
        let frames = BLEFragments.split(Data(repeating: 0, count: 100), id: 2, maximum: 20)
        _ = assembly.accept(frames[0]); precondition(assembly.accept(frames[2]) == nil)
        // Clipboard limits must leave room for JSON escaping and the encrypted envelope.
        for text in [String(repeating: "x", count: 4096), String(repeating: "😀", count: 1024),
                     String(repeating: "\u{1}", count: 916)] {
            let clipboard = try client.seal(["type": "clipboardSet", "text": text])
            check(clipboard.count <= 8192)
            let reply = try exchange(JSONSerialization.jsonObject(with: clipboard) as! [String: Any])
            check(try JSONSerialization.data(withJSONObject: reply).count <= 8192)
            check(try client.open(reply)["text"] as? String == text)
        }
        // URL-safe file payloads avoid slash escaping inflating binary-heavy JSON.
        for byte: UInt8 in [0, 42, 255] {
            let binary = Data(repeating: byte, count: 3072)
            let encoded = binary.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let chunk: [String: Any] = ["type": "clipboardFileChunk", "id": UUID().uuidString, "offset": 4_999_998, "data": encoded]
            let envelope = try client.seal(chunk)
            check(envelope.count <= 8192)
            // Optional JSON slash escapes must not inflate encrypted Base64.
            // Parsing and exchanging this exact envelope still exercises Android
            // authentication/decryption and preserves the original binary data.
            check(!String(decoding: envelope, as: UTF8.self).contains("\\/"))
            let reply = try exchange(JSONSerialization.jsonObject(with: envelope) as! [String: Any], wire: envelope)
            check(try JSONSerialization.data(withJSONObject: reply).count <= 8192)
            check(try client.open(reply)["data"] as? String == encoded)
        }
        // Scheduling must happen before sealing; both peers must still accept
        // directional sequences after control traffic overtakes queued file data.
        var scheduled = BLEOutboundQueue()
        check(scheduled.append(["type": "clipboardFileChunk", "text": "bulk"], deadline: 60))
        check(scheduled.append(["type": "ping", "text": "control"], deadline: 60))
        for expected in ["control", "bulk"] {
            let event = scheduled.next(now: 1)!.object
            check(event["text"] as? String == expected)
            let sealed = try client.seal(event)
            let reply = try exchange(JSONSerialization.jsonObject(with: sealed) as! [String: Any])
            check(try client.open(reply)["text"] as? String == expected)
        }
        // An entire negotiated clipboard window must fit the bounded queue,
        // yield to control traffic, and retain valid encrypted sequence ordering.
        let windowData = Data(repeating: 255, count: 3072).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let windowID = UUID().uuidString
        for offset in stride(from: 0, to: 8 * 3072, by: 3072) {
            check(scheduled.append(["type": "clipboardFileChunk", "id": windowID, "offset": offset, "data": windowData], deadline: 60))
        }
        check(scheduled.append(["type": "ping", "text": "window-control"], deadline: 60))
        check(scheduled.next(now: 1)!.object["text"] as? String == "window-control")
        for offset in stride(from: 0, to: 8 * 3072, by: 3072) {
            let event = scheduled.next(now: 1)!.object
            check(event["offset"] as? Int == offset)
            let sealed = try client.seal(event)
            // Use real fragment reassembly on each encrypted message before exchange.
            var receiver = BLEFragments()
            var assembled: Data?
            for frame in BLEFragments.split(sealed, id: UInt32(offset + 1), maximum: 185) {
                assembled = receiver.accept(frame)
            }
            check(assembled == sealed)
            let reply = try exchange(JSONSerialization.jsonObject(with: assembled!) as! [String: Any])
            check(try client.open(reply)["data"] as? String == windowData)
        }
        check(scheduled.count == 0)
        try input.fileHandleForWriting.close(); task.waitUntilExit(); precondition(task.terminationStatus == 0)
        var delayed = BLEFragments()
        let delayedData = Data(repeating: 42, count: 300)
        let delayedFrames = BLEFragments.split(delayedData, id: 901, maximum: 185)
        check(delayed.accept(delayedFrames[0], now: 1000) == nil)
        check(delayed.accept(delayedFrames[1], now: 1006) == delayedData)
        check(delayed.lastMessageStartedAt == 1000)
        var expired = BLEFragments()
        check(expired.accept(delayedFrames[0], now: 1000) == nil)
        check(expired.accept(delayedFrames[1], now: 1016) == nil)
        print("PASS: Swift ↔ Android Kotlin mutual authentication, AES-GCM, tampering, replay, duplicate handshake, fragmentation")
    }
}
