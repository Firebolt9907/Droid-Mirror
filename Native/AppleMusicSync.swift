import AppKit

/// Apple Music only. Scripts run serially away from the UI and never launch Music.
protocol AppleMusicAccess: AnyObject {
    var snapshot: MediaSnapshot? { get }
    var status: String { get }
    func clear()
    func poll(_ completion: @escaping ([String: Any]) -> Void)
    func command(_ event: [String: Any])
}

final class AppleMusicSync: AppleMusicAccess {
    static let snapshotScript = """
    if application id "com.apple.Music" is not running then return {}
    tell application id "com.apple.Music"
        if player state is stopped then return {}
        return {persistent ID of current track, name of current track, artist of current track, album of current track, (player state is playing), duration of current track, player position}
    end tell
    """

    private let queue = DispatchQueue(label: "app.droidmirror.apple-music")
    private var busy = false
    private(set) var snapshot: MediaSnapshot?
    private(set) var status = "Waiting for Apple Music"
    private let lock = NSLock()
    private var generation = 0
    private var epoch: Int { lock.withLock { generation } }

    func clear() { lock.withLock { generation += 1 }; snapshot = nil }

    func poll(_ completion: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            snapshot = nil; status = "Apple Music is closed"; completion(["active": false]); return
        }
        busy = true
        let epoch = self.epoch
        queue.async {
            let source = Self.snapshotScript
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            var value: [String: Any] = ["active": false]
            if error == nil, let result, result.numberOfItems == 7,
               let id = result.atIndex(1)?.stringValue, !id.isEmpty {
                value = ["active": true, "id": id,
                    "title": String((result.atIndex(2)?.stringValue ?? "").prefix(240)),
                    "artist": String((result.atIndex(3)?.stringValue ?? "").prefix(240)),
                    "album": String((result.atIndex(4)?.stringValue ?? "").prefix(240)),
                    "playing": result.atIndex(5)?.booleanValue ?? false,
                    "duration": max(0, result.atIndex(6)?.doubleValue ?? 0),
                    "position": max(0, result.atIndex(7)?.doubleValue ?? 0),
                    "actions": ["play", "pause", "next", "previous", "seek"]]
            }
            let snapshotValue = value
            DispatchQueue.main.async {
                self.busy = false
                guard epoch == self.epoch else { return }
                self.snapshot = MediaSnapshot(snapshotValue)
                self.status = denied ? "Allow Music in System Settings → Privacy & Security → Automation" :
                    (error != nil ? "Apple Music metadata unavailable" : "Apple Music connected")
                completion(snapshotValue)
            }
        }
    }

    func command(_ event: [String: Any]) {
        guard let snapshot, snapshot.fresh(),
              MediaSnapshot.validCommand(event, target: snapshot.id, actions: snapshot.actions),
              snapshot.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        let operation: String
        switch event["action"] as? String {
        case "play": operation = "play"
        case "pause": operation = "pause"
        case "next": operation = "next track"
        case "previous": operation = "previous track"
        case "seek":
            guard let position = event["position"] as? Double else { return }
            operation = "set player position to \(min(snapshot.duration > 0 ? snapshot.duration : 604800, position))"
        default: return
        }
        // Only fixed commands, a validated hex identifier and a finite number
        // enter the script. Recheck the track in Music before applying controls.
        let source = """
        if application id "com.apple.Music" is not running then return
        tell application id "com.apple.Music"
            if player state is stopped then return
            if persistent ID of current track is not "\(snapshot.id)" then return
            \(operation)
        end tell
        """
        let epoch = self.epoch
        queue.async {
            guard self.epoch == epoch, snapshot.fresh() else { return }
            _ = NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }
}
