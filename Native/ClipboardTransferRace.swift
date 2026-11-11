import Foundation
import CryptoKit

/// Main-queue arbitration. Each lane assembles and hashes its own full copy.
/// Existing ClipboardSync owns destination-change checks and the single apply.
final class ClipboardTransferRace {
    var wire: (Int, [String: Any]) -> Bool = { _, _ in false }
    var deliver: ([String: Any]) -> Void = { _ in }
    var started: () -> Void = {}
    var won: (Int) -> Void = { _ in }
    private(set) var activeID: String?
    private var disabled = Set<Int>()
    private func transmit(_ lane: Int, _ event: [String: Any]) -> Bool {
        guard !disabled.contains(lane) else { return false }
        let ok = wire(lane, event); if !ok { disabled.insert(lane) }; return ok
    }
    private var installOutgoing = false
    private var installLane: Int?
    private var installSize = 0
    private var history = [[String: Any]]()
    private var historyCost = 0
    private var outgoing = ""
    private var sent = 0
    private var ack = -1
    private var incoming = ""
    private var size = 0
    private var digest = ""
    private var window = 1
    private final class Copy { var data = Data(); var chunks = 0 }
    private var copies = [Int: Copy]()
    private var chunks = [Int: Int]()
    private var finished = [String]()
    private var injecting = false
    private var winner = 0
    func send(_ event: [String: Any]) -> Bool {
        let type = event["type"] as? String ?? "", id = event["id"] as? String ?? ""
        if type == "clipboardFileBegin" {
            installOutgoing = event["destination"] as? String == "install"; installLane = nil
            installSize = event["size"] as? Int ?? 0
        }
        if installOutgoing && (type == "clipboardFileBegin" || id == outgoing) {
            if type == "clipboardFileBegin" {
                guard ApkInstallPolicy.allowed(installSize), let name = event["name"] as? String, ApkInstallPolicy.nameAllowed(name) else { return false }
                activeID = id; outgoing = id; sent = 0; ack = -1; history = []; historyCost = 0; disabled = []; started()
            }
            if type == "clipboardFileChunk" {
                guard event["offset"] as? Int == sent, let encoded = event["data"] as? String,
                      let data = decode(encoded), (1...3072).contains(data.count), sent + data.count <= installSize else { return false }
                sent += data.count
            }
            if type == "clipboardFileCancel" { activeID = nil; remember(id) }
            if let lane = installLane { return transmit(lane, event) }
            for lane in [1, 0] where transmit(lane, event) { installLane = lane; return true }
            return false
        }
        if id == incoming && type == "clipboardFileAck" && (event["offset"] as? Int ?? 0) > 0 && event["offset"] as? Int != size { return true }
        if type == "clipboardFileBegin" {
            activeID = id; started(); disabled = []; outgoing = id; history = []; historyCost = 0; sent = 0; ack = -1
        }
        if type == "clipboardFileBegin" || type == "clipboardFileChunk" {
            let cost = (try? JSONSerialization.data(withJSONObject: event).count) ?? 8_000_001
            guard historyCost + cost <= 7_000_000 else { return false }
            history.append(event); historyCost += cost
            if type == "clipboardFileChunk", let encoded = event["data"] as? String, let data = decode(encoded) { sent += data.count }
        }
        if type == "clipboardFileCancel" {
            if activeID == id { activeID = nil }
            remember(id)
            if id == incoming { copies = [:]; chunks = [:] }
            if id == outgoing { history = []; historyCost = 0 }
        }
        let a = transmit(0, event), b = transmit(1, event)
        if id == incoming && type == "clipboardFileAck" && event["offset"] as? Int == size { activeID = nil; disabled.insert(1 - winner); won(winner) }
        return a || b
    }
    func restartLane(_ lane: Int) {
        disabled.remove(lane); copies.removeValue(forKey: lane); chunks.removeValue(forKey: lane)
    }
    /// Replay only the active source transfer when a late lane becomes available.
    func catchUp(_ lane: Int) {
        for event in history { if !wire(lane, event) { break } }
    }
    private func decode(_ value: String) -> Data? { Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) }
    private func remember(_ id: String) { finished.append(id); if finished.count > 64 { finished.removeFirst() } }
    func receive(_ event: [String: Any], lane: Int) {
        guard let id = event["id"] as? String, UUID(uuidString: id) != nil else { return }
        let type = event["type"] as? String ?? ""
        if type == "clipboardFileAck" {
            guard id == outgoing, let offset = event["offset"] as? Int, offset == sent, offset > ack else { return }
            ack = offset
            if history.first?["size"] as? Int == offset || (installOutgoing && offset == installSize) { activeID = nil }
            if history.first?["size"] as? Int == offset && offset > 0 { history = []; historyCost = 0 }
            deliver(event); return
        }
        if finished.contains(id) { return }
        if type == "clipboardFileCancel" {
            if activeID == id { activeID = nil }
            if id == outgoing { history = []; historyCost = 0 }
            remember(id); deliver(event); return
        }
        if type == "clipboardFileBegin" {
            guard let n = event["size"] as? Int, (0..<5_000_000).contains(n), let hash = event["sha256"] as? String,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return }
            if n == 0 && hash != SHA256.hash(data: Data()).map({ String(format: "%02x", $0) }).joined() { return }
            if id != incoming {
                activeID = id; started(); disabled = []; incoming = id; size = n; digest = hash; window = max(1, min(32, event["window"] as? Int ?? 1)); copies = [:]; chunks = [:]
                copies[lane] = Copy(); chunks[lane] = 0
                if n == 0 { winner = lane; remember(id) }
                deliver(event)
            } else if n == size && hash == digest && copies[lane] == nil {
                copies[lane] = Copy(); chunks[lane] = 0
                _ = transmit(lane, ["type": "clipboardFileAck", "id": id, "offset": 0, "window": window])
            }
            return
        }
        guard type == "clipboardFileChunk", id == incoming, let copy = copies[lane],
              event["offset"] as? Int == copy.data.count, let encoded = event["data"] as? String,
              let chunk = decode(encoded), (1...3072).contains(chunk.count), copy.data.count + chunk.count <= size else { return }
        copy.data.append(chunk); chunks[lane, default: 0] += 1
        if copy.data.count == size {
            let data = copy.data
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { copies.removeValue(forKey: lane); return }
            remember(id); winner = lane; injecting = true
            // Replay to the existing receiver only after one full copy verifies.
            for offset in stride(from: 0, to: size, by: 3072) {
                deliver(["type": "clipboardFileChunk", "id": id, "offset": offset,
                         "data": data.subdata(in: offset..<min(size, offset + 3072)).base64EncodedString()])
            }
            injecting = false; copies = [:]; chunks = [:]
        } else if chunks[lane]! % window == 0 {
            deliver(["type": "clipboardFileRaceProgress", "id": id])
            _ = transmit(lane, ["type": "clipboardFileAck", "id": id, "offset": copy.data.count])
        }
    }
}
