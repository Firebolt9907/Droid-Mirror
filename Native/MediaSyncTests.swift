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
    var polls = 0
    func poll(_ completion: @escaping ([String: Any]) -> Void) { polls += 1; snapshot = MediaSnapshot(value); completion(value) }
    func command(_ value: [String: Any]) { commands.append(value) }
}
@main struct MediaSyncTests {
    static func main() {
        // Phone volume keys: decoding, reply validation and HUD prediction.
        if case .press(let action)? = VolumeKeyEvent.decode(subtype: 8, data1: 0x0000_0a00) { precondition(action == "up") } else { preconditionFailure() }
        if case .press(let action)? = VolumeKeyEvent.decode(subtype: 8, data1: 0x0001_0a01) { precondition(action == "down") } else { preconditionFailure() }
        if case .press(let action)? = VolumeKeyEvent.decode(subtype: 8, data1: 0x0007_0a00) { precondition(action == "mute") } else { preconditionFailure() }
        if case .release? = VolumeKeyEvent.decode(subtype: 8, data1: 0x0000_0b00) {} else { preconditionFailure() }
        precondition(VolumeKeyEvent.decode(subtype: 8, data1: 0x0010_0a00) == nil, "Play/pause is left to Now Playing")
        precondition(VolumeKeyEvent.decode(subtype: 7, data1: 0x0000_0a00) == nil)
        let volumeEvent: [String: Any] = ["type": "mediaVolumeState", "id": "phone", "level": 7, "max": 15, "muted": false, "name": "Pixel"]
        let volume = PhoneVolumeState(volumeEvent, expectedID: "phone")!
        precondition(volume.name == "Pixel" && abs(volume.fraction - 7.0 / 15) < 1e-9)
        precondition(PhoneVolumeState(volumeEvent, expectedID: "other") == nil, "Replies are bound to the advertised session")
        var badVolume = volumeEvent; badVolume["level"] = 16
        precondition(PhoneVolumeState(badVolume, expectedID: "phone") == nil)
        badVolume = volumeEvent; badVolume["max"] = 0
        precondition(PhoneVolumeState(badVolume, expectedID: "phone") == nil)
        precondition(volume.predicting("up").level == 8 && volume.predicting("down").level == 6)
        precondition(volume.predicting("mute").muted && volume.predicting("mute").fraction == 0)
        precondition(volume.predicting("mute").predicting("up").muted == false)
        let full = PhoneVolumeState(id: "phone", level: 15, max: 15, muted: false, name: "")
        precondition(full.predicting("up").level == 15 && PhoneVolumeState(id: "phone", level: 0, max: 15, muted: false, name: "").predicting("down").level == 0)
        var scriptError: NSDictionary?
        precondition(NSAppleScript(source: AppleMusicSync.snapshotScript)?.compileAndReturnError(&scriptError) == true,
                     "Music script must compile against its installed scripting dictionary: \(String(describing: scriptError))")
        for operation in ["set shuffle enabled to true", "set shuffle enabled to false",
                          "set song repeat to off", "set song repeat to all", "set song repeat to one"] {
            scriptError = nil
            precondition(NSAppleScript(source: "tell application id \"com.apple.Music\" to " + operation)?.compileAndReturnError(&scriptError) == true,
                         "Music control must compile: \(operation): \(String(describing: scriptError))")
        }
        precondition(MusicCatalogArtwork.catalogID("1698723328") == "1698723328")
        precondition(MusicCatalogArtwork.catalogID("../track") == nil)
        precondition(MusicCatalogArtwork.catalogID("0") == nil)
        precondition(MusicCatalogArtwork.imageURL("https://is1-ssl.mzstatic.com/image/100x100bb.jpg")?.lastPathComponent == "512x512bb.jpg")
        for url in ["http://is1-ssl.mzstatic.com/image/100x100bb.jpg", "https://example.com/image/100x100bb.jpg",
                    "https://mzstatic.com.example.com/image/100x100bb.jpg", "https://user@is1-ssl.mzstatic.com/image/100x100bb.jpg"] {
            precondition(MusicCatalogArtwork.imageURL(url) == nil)
        }
        let now = Date()
        let value: [String: Any] = ["type": "mediaState", "active": true, "id": "abc", "title": "Phone song",
            "artist": "Artist", "album": "Album", "playing": true, "duration": 120.0, "position": 20.0,
            "actions": ["play", "pause", "next", "seek"]]
        let rawQueue: [String: Any] = ["available": true, "owner": 123, "queueID": "queue-1", "current": "native-current",
            "entries": [["key": "native-current", "title": "Phone song", "artist": "Artist"],
                        ["key": "native-next", "title": "Queued song", "artist": "Artist"]]]
        var native = rawQueue
        native["playback"] = ["title": "Phone song", "artist": "Artist", "album": "Album", "playing": true,
            "shuffle": false, "repeat": "off", "duration": 120.0, "position": 20.0,
            "actions": ["play", "pause", "next", "previous", "seek", "shuffle", "repeat", "queue"]]
        let nativeSnapshot = MusicPlaybackQueue.nativeSnapshot(native)!
        precondition(MediaSnapshot(nativeSnapshot) != nil)
        let nativeQueue = MusicPlaybackQueue(native, snapshot: nativeSnapshot, now: now)!
        let nativeCommand: [String: Any] = ["id": nativeSnapshot["id"]!, "action": "seek", "position": 30.0]
        precondition(nativeQueue.control(nativeCommand, now: now)?["control"] as? String == "seek")
        precondition(nativeQueue.control(nativeCommand, now: now.addingTimeInterval(8)) == nil)
        native["owner"] = 456
        precondition(MusicPlaybackQueue.nativeSnapshot(native)?["id"] as? String != nativeSnapshot["id"] as? String)
        let musicQueue = MusicPlaybackQueue(rawQueue, snapshot: value, now: now)!
        precondition(musicQueue.items.count == 2)
        var selection: [String: Any] = ["id": "abc", "action": "queue", "queueRevision": musicQueue.revision,
            "queueItemId": musicQueue.items[1].id]
        precondition(musicQueue.selection(selection, now: now)?["target"] as? String == "native-next")
        precondition(musicQueue.selection(selection, now: now.addingTimeInterval(8)) == nil)
        selection["queueRevision"] = "stale"; precondition(musicQueue.selection(selection, now: now) == nil)
        selection["queueRevision"] = musicQueue.revision; selection["queueItemId"] = Int64(-1)
        precondition(musicQueue.selection(selection, now: now) == nil)
        var replacement = rawQueue; replacement["queueID"] = "queue-2"
        let replacedQueue = MusicPlaybackQueue(replacement, snapshot: value, now: now)!
        precondition(replacedQueue.revision != musicQueue.revision && replacedQueue.items[1].id != musicQueue.items[1].id)
        replacement = rawQueue; replacement["owner"] = 456
        precondition(MusicPlaybackQueue(replacement, snapshot: value, now: now)!.revision != musicQueue.revision)
        replacement = rawQueue; replacement["entries"] = [["key": "wrong", "title": "Different song", "artist": "Artist"]]
        precondition(MusicPlaybackQueue(replacement, snapshot: value) == nil)
        precondition(try! JSONSerialization.data(withJSONObject: musicQueue.event).count <= 5200)
        // Exercise the actual JSON number round trip used by BLE on both platforms.
        let encoded = try! JSONSerialization.data(withJSONObject: musicQueue.event)
        let decoded = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition((decoded["items"] as! [[String: Any]])[1]["queueItemId"] as? Int64 == musicQueue.items[1].id)
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
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cover = MediaArtwork.encode(bitmap.representation(using: .png, properties: [:])!)!
        precondition(Data(base64Encoded: cover)!.count <= MediaArtwork.maximumBytes)
        let image = MediaArtwork.decode(cover)!
        precondition(image.size.width == 512 && image.size.height == 256)
        precondition(MediaArtwork.decode("invalid base64") == nil)
        precondition(MediaArtwork.decode(String(repeating: "A", count: MediaArtworkTransfer.maximumLength + 1)) == nil)
        precondition(MediaArtwork.encode(Data("not an image".utf8)) == nil)
        // Small compressed files may still declare huge dimensions: reject before decoding.
        let oversized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        precondition(MediaArtwork.decode(oversized.representation(using: .jpeg,
            properties: [.compressionFactor: 0.1])!.base64EncodedString()) == nil)
        let sender = MediaArtworkTransfer(), receiver = MediaArtworkTransfer()
        let payload = String(repeating: "YWJj", count: 3000)
        let announcement = sender.prepare(["artwork": payload])
        precondition(announcement["artwork"] == nil)
        receiver.observe(announcement)
        let first = receiver.request(now: now)!
        precondition(receiver.request(now: now) == nil)
        precondition(receiver.request(now: now.addingTimeInterval(1)) != nil)
        var bad = sender.reply(first)!; bad["offset"] = -1
        precondition(!receiver.receive(bad))
        precondition(receiver.receive(sender.reply(first)!))
        while receiver.completed == nil {
            let request = receiver.request(now: now)!
            let reply = sender.reply(request)!
            precondition(try! JSONSerialization.data(withJSONObject: reply).count < 5200)
            precondition(receiver.receive(reply))
        }
        precondition(receiver.completed == payload)
        receiver.observe([:]); precondition(receiver.completed == nil)
        precondition(!receiver.receive(sender.reply(first)!))
        receiver.observe(announcement)
        bad = sender.reply(receiver.request(now: now)!)!
        bad["data"] = String(repeating: "X", count: 4096)
        precondition(receiver.receive(bad))
        while let request = receiver.request(now: now) { precondition(receiver.receive(sender.reply(request)!)) }
        precondition(receiver.completed == nil)
        var extended = value; extended["actions"] = ["shuffle", "repeat"]
        precondition(MediaSnapshot(extended) != nil)
        precondition(!MediaSnapshot.validCommand(["id": "abc", "action": "shuffle"], target: "abc", actions: ["shuffle"]))
        precondition(MediaSnapshot.validCommand(["id": "abc", "action": "shuffle", "enabled": true], target: "abc", actions: ["shuffle"]))
        precondition(!MediaSnapshot.validCommand(["id": "abc", "action": "repeat", "mode": "execute"], target: "abc", actions: ["repeat"]))
        precondition(MediaSnapshot.validCommand(["id": "abc", "action": "repeat", "mode": "one"], target: "abc", actions: ["repeat"]))
        var lease = PhoneMediaKeyLease()
        var leasePaused = value; leasePaused["playing"] = false
        let pausedSnapshot = MediaSnapshot(leasePaused)!
        lease.observe(pausedSnapshot, now: 0)
        precondition(!lease.allows(pausedSnapshot, now: 1))
        lease.observe(MediaSnapshot(value), now: 1)
        lease.observe(pausedSnapshot, now: 2)
        precondition(lease.allows(pausedSnapshot, now: 601))
        precondition(!lease.allows(pausedSnapshot, now: 602))
        lease.invalidate()
        precondition(!lease.allows(pausedSnapshot, now: 3))
        var external = leasePaused; external["externalAudio"] = true
        precondition(lease.allows(MediaSnapshot(external)!, now: 1000))
        var different = leasePaused; different["id"] = "different"
        lease.observe(MediaSnapshot(value), now: 4)
        lease.observe(pausedSnapshot, now: 5)
        lease.observe(MediaSnapshot(different), now: 6)
        precondition(!lease.allows(MediaSnapshot(different)!, now: 7))
        // Republish only when the published content changes.
        let published = MediaSnapshot(value, uptime: 10)!
        precondition(published.publicationKey == MediaSnapshot(value, uptime: 10)!.publicationKey)
        precondition(published.publicationKey != MediaSnapshot(value, uptime: 11)!.publicationKey)
        var moved = value; moved["position"] = (value["position"] as! Double) + 30
        precondition(published.publicationKey != MediaSnapshot(moved, uptime: 10)!.publicationKey)

        // Reads follow change signals, with a timer only for unannounced changes.
        precondition(MusicPollSchedule.interval(localTimeline: false, playing: false, screenAwake: true) == 2,
                     "Legacy peers need a heartbeat inside their 8-second lease")
        precondition(MusicPollSchedule.interval(localTimeline: true, playing: true, screenAwake: true) == 10)
        precondition(MusicPollSchedule.interval(localTimeline: true, playing: true, screenAwake: false) == 30)
        precondition(MusicPollSchedule.interval(localTimeline: true, playing: false, screenAwake: true) == 60)
        var schedule = MusicPollSchedule()
        precondition(schedule.due(now: 0), "A new subscription reads at once")
        schedule.begin(now: 0)
        precondition(!schedule.due(now: 1), "One read at a time")
        schedule.requestSoon()
        precondition(!schedule.due(now: 1), "A change signal waits for the read in flight")
        schedule.finish(now: 1, interval: 60)
        precondition(schedule.due(now: 1), "A signal during a read must not be lost")
        schedule.begin(now: 1); schedule.finish(now: 1, interval: 60)
        precondition(!schedule.soon && !schedule.due(now: 60) && schedule.due(now: 61))
        schedule.begin(now: 61)
        precondition(!schedule.due(now: 68) && schedule.due(now: 69), "A dropped completion must not stop reads forever")
        schedule.reset()
        precondition(schedule.due(now: 0))

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
        var paused = value
        paused["playing"] = false
        sync.receive(paused)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil, "A retained paused phone session must not claim Now Playing")
        var connectedValue = value; connectedValue["externalAudio"] = true
        sync.receive(connectedValue)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Phone song")
        sync.receive(paused)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil, "Recent pause must retain Now Playing")
        precondition(MPNowPlayingInfoCenter.default().playbackState == .paused)
        precondition(MPRemoteCommandCenter.shared().playCommand.isEnabled)
        sync.receive(connectedValue)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Phone song")
        sync.receive(["type": "mediaState", "active": false])
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil, "Ending phone playback must remove Now Playing")
        sync.receive(connectedValue)
        var illustrated = connectedValue
        illustrated["artwork"] = cover
        sync.receive(illustrated)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        illustrated["artwork"] = "invalid"
        sync.receive(illustrated)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
        sync.receive(connectedValue)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
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
        sync.receive(connectedValue)
        precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil, "No app-specific Music priority")
        NotificationRuntime.preferences.set(false, forKey: MediaPlaybackSync.enabledKey)
        sync.configure()
        sync.receive(["type": "mediaCommand", "id": "music", "action": "pause"])
        precondition(music.commands.count == 1)
        // A command never acts on a stale snapshot: it reads first, then runs once.
        NotificationRuntime.preferences.set(true, forKey: MediaPlaybackSync.enabledKey)
        sync.configure()
        music.snapshot = nil; music.value = ["active": false]
        let readsBefore = music.polls
        sync.receive(["type": "mediaCommand", "id": "music", "action": "play"])
        precondition(music.polls == readsBefore + 1 && music.commands.count == 2)
        sync.stop()
        NotificationRuntime.preferences.removePersistentDomain(forName: "app.droidmirror.media-tests.\(ProcessInfo.processInfo.processIdentifier)")
        print("PASS: media validation, expiry, commands, opt-in, routing, pause lease, external audio, disconnect cleanup and app-neutral eligibility")
    }
}
