import AppKit
import MediaPlayer

final class BLEController {
    var authenticated = true
    var supportsMedia = true
    var sent = [[String: Any]]()
    @discardableResult func send(_ value: [String: Any]) -> Bool {
        guard authenticated else { return false }
        sent.append(value); return true
    }
}
enum NotificationRuntime { static let preferences = UserDefaults(suiteName: "app.droidmirror.media-tests.\(ProcessInfo.processInfo.processIdentifier)")! }
final class MusicStub: AppleMusicAccess {
    var snapshot: MediaSnapshot?
    var status = "Test Music"
    var value: [String: Any] = ["active": false]
    var commands = [[String: Any]]()
    func clear() { snapshot = nil }
    func poll(_ completion: @escaping ([String: Any]) -> Void) { snapshot = MediaSnapshot(value); completion(value) }
    func command(_ value: [String: Any]) { commands.append(value) }
}
@main struct MediaSyncTests {
    static func main() {
        var scriptError: NSDictionary?
        precondition(NSAppleScript(source: AppleMusicSync.snapshotScript)?.compileAndReturnError(&scriptError) == true,
                     "Music script must compile against its installed scripting dictionary: \(String(describing: scriptError))")
        let now = Date()
        let value: [String: Any] = ["type": "mediaState", "active": true, "id": "abc", "title": "Phone song",
            "artist": "Artist", "album": "Album", "playing": true, "duration": 120.0, "position": 20.0,
            "actions": ["play", "pause", "next", "seek"]]
        let state = MediaSnapshot(value, now: now)!
        precondition(state.fresh(now: now.addingTimeInterval(7)))
        precondition(!state.fresh(now: now.addingTimeInterval(8)))
        precondition(state.elapsed(now: now.addingTimeInterval(3)) == 23)
        precondition(state.elapsed(now: now.addingTimeInterval(200)) == 120)
        var invalid = value
        for key in ["id", "title", "artist", "album", "duration", "position", "playing", "actions"] {
            invalid = value; invalid.removeValue(forKey: key); precondition(MediaSnapshot(invalid) == nil)
        }
        for position in [Double.nan, .infinity, -1] {
            invalid = value; invalid["position"] = position; precondition(MediaSnapshot(invalid) == nil)
        }
        invalid = value; invalid["actions"] = ["execute"]; precondition(MediaSnapshot(invalid) == nil)
        precondition(!MediaSnapshot.validCommand(["id": "stale", "action": "pause"], target: state.id, actions: state.actions))
        precondition(!MediaSnapshot.validCommand(["id": "abc", "action": "previous"], target: state.id, actions: state.actions))
        precondition(!MediaSnapshot.validCommand(["id": "abc", "action": "seek", "position": Double.nan], target: state.id, actions: state.actions))
        precondition(MediaSnapshot.validCommand(["id": "abc", "action": "seek", "position": 30.0], target: state.id, actions: state.actions))
        let controller = BLEController()
        let music = MusicStub()
        let sync = MediaPlaybackSync(music: music)
        sync.controller = controller
        NotificationRuntime.preferences.set(false, forKey: MediaPlaybackSync.enabledKey)
        sync.connected()
        precondition(controller.sent.last?["enabled"] as? Bool == false)
        NotificationRuntime.preferences.set(true, forKey: MediaPlaybackSync.enabledKey)
        sync.configure()
        precondition(controller.sent.contains { $0["type"] as? String == "mediaSubscribe" && $0["enabled"] as? Bool == true })
        sync.receive(value)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Phone song")
        sync.receive(["type": "mediaCommand", "id": "music", "action": "pause"])
        precondition(music.commands.count == 1)
        controller.authenticated = false
        sync.receive(["type": "mediaCommand", "id": "music", "action": "pause"])
        precondition(music.commands.count == 1)
        sync.clear()
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        controller.authenticated = true
        music.value = value
        sync.connected()
        sync.receive(value)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil, "Local Music playback takes priority")
        NotificationRuntime.preferences.set(false, forKey: MediaPlaybackSync.enabledKey)
        sync.configure()
        sync.receive(["type": "mediaCommand", "id": "music", "action": "pause"])
        precondition(music.commands.count == 1)
        sync.stop()
        NotificationRuntime.preferences.removePersistentDomain(forName: "app.droidmirror.media-tests.\(ProcessInfo.processInfo.processIdentifier)")
        print("PASS: media validation, expiry, commands, opt-in, routing, disconnect cleanup and local Music priority")
    }
}
