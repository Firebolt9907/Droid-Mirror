import Foundation
import CryptoKit

// Host-only workload: production scheduling/crypto/framing, modeled radio timing.
// One frame per callback is an assumption, not a Core Bluetooth throughput claim.
@main struct BLETransportBenchmark {
    static func session(_ generation: UInt8) throws -> BLESecureSession {
        let key = Data(repeating: 7, count: 32)
        let mac = Data(repeating: generation, count: 32)
        let phone = Data(repeating: 11, count: 32)
        let client = try BLESecureSession(key: key, nonce: mac)
        let master = SymmetricKey(data: key)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("phone".utf8) + mac + phone, using: master))
        _ = try client.challenge(["nonce": phone.base64EncodedString(), "proof": proof.base64EncodedString()])
        let receiveKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: mac + phone,
            info: Data("DroidMirror BLE v2 phone".utf8), outputByteCount: 32)
        var seq = UInt64(1).bigEndian
        let iv = Data("DM2P".utf8) + withUnsafeBytes(of: &seq) { Data($0) }
        let ready = try AES.GCM.seal(Data("{\"type\":\"ready\"}".utf8), using: receiveKey,
            nonce: AES.GCM.Nonce(data: iv), authenticating: iv)
        _ = try client.open(["seq": 1, "box": ready.combined!.base64EncodedString()])
        return client
    }

    struct Flight {
        let frames: [Data]
        let sealed: Data
        let plainBytes: Int
        let enqueued: Int
        let control: Bool
        let ping: Bool
        var index = 0
    }

    static func run(mtu: Int, frameMS: Int, stall: Bool = false, disconnect: Bool = false, windowSize: Int = 0) throws -> [String: Any] {
        var queue = BLEOutboundQueue()
        var client = try session(1)
        var flight: Flight?
        var assembly = BLEFragments()
        var nextFrame = 0, end = 0, highWater = 0
        var accepted = 0, rejected = 0, expired = 0, canceled = 0, delivered = 0
        var wireBytes = 0, usefulBytes = 0, encryptedBytes = 0, frameCount = 0
        var deliveredWireBytes = 0, escapedEquivalentBytes = 0, escapedEquivalentFrames = 0
        var latency = [Int](), queueDelay = [Int]()
        var pingLatency = [Int]()
        var chunksRemaining = windowSize > 0 ? 16 : 0
        var windowOutstanding = 0, ackDue = 0, offset = 0
        var id: UInt32 = 0
        var disconnected = false
        for now in 0...120_000 {
            end = now
            if disconnect && now == 1525 {
                // Retire all old-session work; never replay side effects.
                canceled += queue.count + (flight == nil ? 0 : 1)
                queue.reset(); flight = nil; assembly = BLEFragments()
                disconnected = true
            }
            if disconnect && now == 1725 {
                client = try session(2); disconnected = false
            }
            if windowSize > 0 && chunksRemaining > 0 && windowOutstanding == 0 && now >= ackDue {
                // Model the producer's bounded cumulative-ACK window. Reverse
                // ACK transport is simplified to two callback intervals.
                for _ in 0..<min(windowSize, chunksRemaining) {
                    let chunk: [String: Any] = ["type": "clipboardFileChunk", "id": "synthetic-file",
                        "offset": offset, "data": Data(repeating: 42, count: 3072).base64EncodedString(), "enqueued": now]
                    precondition(queue.append(chunk, deadline: Double(now + 60_000) / 1000))
                    offset += 3072; chunksRemaining -= 1; windowOutstanding += 1; accepted += 1
                }
                highWater = max(highWater, queue.bytes)
            }
            if now < 3000 && (now % 80 == 0 || now % 50 == 0) {
                var messages = [[String: Any]]()
                if windowSize == 0 && now % 80 == 0 {
                    messages.append(["type": "clipboardFileChunk", "data": String(repeating: "x", count: 1000), "enqueued": now])
                }
                if now % 50 == 0 { messages.append(["type": "mediaCommand", "command": "pause", "enqueued": now]) }
                if windowSize > 0 && now % 500 == 0 { messages.append(["type": "ping", "enqueued": now]) }
                for message in messages {
                    if !disconnected && queue.append(message, deadline: Double(now + 60_000) / 1000) { accepted += 1 }
                    else { rejected += 1 }
                }
                highWater = max(highWater, queue.bytes)
            }
            if !disconnected && flight == nil {
                let before = queue.count
                let message = queue.next(now: Double(now) / 1000)
                expired += before - queue.count - (message == nil ? 0 : 1)
                if let message {
                    if !message.bulk { queueDelay.append(now - (message.object["enqueued"] as! Int)) }
                    let sealed = try client.seal(message.object)
                    id &+= 1
                    let frames = BLEFragments.split(sealed, id: id, maximum: mtu - 3)
                    precondition(!frames.isEmpty && frames.allSatisfy { $0.count <= min(mtu - 3, 512) })
                    flight = Flight(frames: frames, sealed: sealed,
                        plainBytes: try JSONSerialization.data(withJSONObject: message.object).count,
                        enqueued: message.object["enqueued"] as! Int, control: !message.bulk,
                        ping: message.object["type"] as? String == "ping")
                    nextFrame = now + frameMS
                }
            }
            // A modeled 500 ms readiness stall, with bounded pending work.
            if stall && now >= 1000 && now < 1500 { continue }
            if var current = flight, now >= nextFrame {
                let frame = current.frames[current.index]
                wireBytes += frame.count; frameCount += 1
                let result = assembly.accept(frame)
                current.index += 1
                if current.index == current.frames.count {
                    precondition(result == current.sealed, "Production fragment reassembly failed")
                    // Same ciphertext, legacy JSON representation: isolates byte
                    // savings from JSON key ordering and ciphertext variation.
                    let envelope = try JSONSerialization.jsonObject(with: current.sealed)
                    let escaped = try JSONSerialization.data(withJSONObject: envelope)
                    let legacyFrames = BLEFragments.split(escaped, id: id, maximum: mtu - 3)
                    deliveredWireBytes += current.frames.reduce(0) { $0 + $1.count }
                    escapedEquivalentBytes += legacyFrames.reduce(0) { $0 + $1.count }
                    escapedEquivalentFrames += legacyFrames.count
                    usefulBytes += current.plainBytes; encryptedBytes += current.sealed.count
                    delivered += 1
                    if current.control { latency.append(now - current.enqueued) }
                    if current.ping { pingLatency.append(now - current.enqueued) }
                    if windowSize > 0 && !current.control {
                        windowOutstanding -= 1
                        if windowOutstanding == 0 { ackDue = now + 2 * frameMS }
                    }
                    flight = nil
                } else { flight = current }
                nextFrame = now + frameMS
            }
            if now >= 3000 && queue.count == 0 && flight == nil && chunksRemaining == 0 && now >= ackDue { break }
        }
        precondition(queue.count == 0 && flight == nil, "Workload did not drain")
        precondition(accepted == delivered + expired + canceled, "Unaccounted message loss")
        latency.sort(); queueDelay.sort(); pingLatency.sort()
        func percentile(_ values: [Int], _ fraction: Double) -> Int {
            values.isEmpty ? 0 : values[max(0, Int(ceil(Double(values.count) * fraction)) - 1)]
        }
        return ["mtu": mtu, "frame_service_ms": frameMS, "readiness_stall": stall, "disconnect": disconnect,
            "file_window": windowSize, "file_payload_bytes": windowSize > 0 ? offset : 0,
            "modeled_file_final_ack_ms": ackDue,
            "modeled_file_payload_bytes_per_second": windowSize > 0 ? Double(offset) * 1000 / Double(max(ackDue, 1)) : 0,
            "ping_samples": pingLatency.count, "ping_completion_p95_ms": percentile(pingLatency, 0.95),
            "modeled_elapsed_ms": end, "accepted": accepted, "rejected": rejected, "expired": expired,
            "disconnect_canceled": canceled, "delivered": delivered, "control_samples": latency.count,
            "control_completion_p50_ms": percentile(latency, 0.50), "control_completion_p95_ms": percentile(latency, 0.95),
            "control_completion_p99_ms": percentile(latency, 0.99),
            "control_queue_p50_ms": percentile(queueDelay, 0.50), "control_queue_p95_ms": percentile(queueDelay, 0.95),
            "control_queue_p99_ms": percentile(queueDelay, 0.99), "queue_reserved_high_water_bytes": highWater,
            "useful_json_bytes": usefulBytes, "encrypted_envelope_bytes": encryptedBytes,
            "att_value_bytes": wireBytes, "frames": frameCount,
            "delivered_att_value_bytes": deliveredWireBytes,
            "same_ciphertext_escaped_equivalent_att_value_bytes": escapedEquivalentBytes,
            "same_ciphertext_escaped_equivalent_frames": escapedEquivalentFrames,
            "modeled_useful_json_bytes_per_second": Double(usefulBytes) * 1000 / Double(max(end, 1)),
            "useful_json_to_att_value_ratio": Double(usefulBytes) / Double(max(wireBytes, 1))]
    }

    static func main() throws {
        let cases = try [run(mtu: 23, frameMS: 8), run(mtu: 185, frameMS: 8), run(mtu: 517, frameMS: 8),
            run(mtu: 517, frameMS: 30), run(mtu: 517, frameMS: 8, stall: true),
            run(mtu: 517, frameMS: 8, disconnect: true),
            run(mtu: 23, frameMS: 8, windowSize: 1), run(mtu: 23, frameMS: 8, windowSize: 8),
            run(mtu: 185, frameMS: 8, windowSize: 1), run(mtu: 185, frameMS: 8, windowSize: 8),
            run(mtu: 517, frameMS: 8, windowSize: 1), run(mtu: 517, frameMS: 8, windowSize: 8)]
        let output: [String: Any] = ["kind": "host simulation; not measured BLE radio performance",
            "assumptions": "3 s deterministic arrivals: 1000-byte file data every 80 ms, control every 50 ms; one ATT value per modeled callback; no RF loss; actual production queue, session sealing and fragments; elapsed includes drain; JSON escaping may change ciphertext lengths between executions; excludes ATT/L2CAP/link headers, CPU time, OS buffers and peer processing",
            "window_assumptions": "file_window > 0 replaces open-loop file arrivals with a 48 KiB file in 3072-byte chunks, windows of 1/8, two-interval cumulative ACK delay, and urgent pings every 500 ms during the 3 s control arrival period; ACK traffic is not simulated in the reverse queue; final ACK time excludes file begin negotiation and OS processing",
            "cases": cases]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
