import AppKit
import MediaPlayer
import IOKit

/// The background receiver is the sole owner of both Now Playing proxies.
final class MediaPlaybackSync {
    static let enabledKey = "DroidMirror.media.enabled"
    weak var controller: BLEController?
    private let music: AppleMusicAccess
    private let artwork = MediaArtworkTransfer()
    private var phoneArtwork: NSImage?
    private var phone: MediaSnapshot?
    private var lease = PhoneMediaKeyLease()
    private var sleepObserver: NSObjectProtocol?
    private var lastCheck = ProcessInfo.processInfo.systemUptime
    private func checkContinuity() {
        let now = ProcessInfo.processInfo.systemUptime
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        var closed = false
        if root != 0 {
            closed = (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true
            IOObjectRelease(root)
        }
        if closed || now - lastCheck > 8 { lease.invalidate() }
        lastCheck = now
    }
    private var phoneEligible: Bool {
        guard let phone else { return false }
        return lease.allows(phone, now: ProcessInfo.processInfo.systemUptime)
    }
    private var timer: Timer?
    private var targets = [(MPRemoteCommand, Any)]()
    private var published = false
    private var subscribed = false
    private var phoneStatus = ""
    private var sentQueueRevision = ""
    private var wire = MediaStateWire()
    private var epoch = 0
    private(set) var status = "Media syncing off"
    private var enabled: Bool { NotificationRuntime.preferences.bool(forKey: Self.enabledKey) }

    init(music: AppleMusicAccess = AppleMusicSync()) {
        self.music = music
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lease.invalidate(); self?.render()
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func connected() { configure() }
    func configure() {
        clear()
        guard controller?.authenticated == true, controller?.supportsMedia == true else { return }
        subscribed = enabled && controller?.send(["type": "mediaSubscribe", "enabled": true]) == true
        if !enabled { controller?.send(["type": "mediaSubscribe", "enabled": false]) }
        tick()
    }
    func receive(_ event: [String: Any]) {
        guard enabled, subscribed, controller?.authenticated == true else { return }
        switch event["type"] as? String {
        case "mediaState":
            guard let event = wire.receive(event) else { return }
            checkContinuity()
            phone = MediaSnapshot(event, sessionScoped: wire.peerSupportsLocalTimeline)
            lease.observe(phone, now: ProcessInfo.processInfo.systemUptime)
            artwork.observe(phone == nil ? [:] : event)
            phoneArtwork = phone == nil ? nil : MediaArtwork.decode(artwork.completed ?? (event["artwork"] as? String))
            requestArtwork()
            render()
        case "mediaArtworkRequest":
            if music.snapshot?.fresh() == true, let reply = artwork.reply(event) { controller?.send(reply) }
        case "mediaArtworkChunk":
            guard phone?.fresh() == true, artwork.receive(event) else { return }
            phoneArtwork = MediaArtwork.decode(artwork.completed)
            requestArtwork(); render()
        case "mediaCommand": music.command(event)
        case "mediaStatus": phoneStatus = event["message"] as? String ?? "Phone media unavailable"
        default: break
        }
    }
    private func tick() {
        guard enabled, subscribed, controller?.authenticated == true else {
            clear()
            status = enabled ? "Waiting for a paired phone with media support" : "Media syncing off"
            return
        }
        render()
        if phone?.fresh() == true { requestArtwork() }
        let generation = epoch
        music.poll { [weak self] value in
            guard let self, self.epoch == generation, self.enabled, self.subscribed,
                  self.controller?.authenticated == true else { return }
            var event = self.artwork.prepare(value); event["type"] = "mediaState"
            let queue = event.removeValue(forKey: "_queue") as? [String: Any]
            var candidate = self.wire
            let message = candidate.prepare(event)
            if message == nil || self.controller?.send(message!) == true {
                self.wire = candidate
                if let queue, let revision = queue["revision"] as? String {
                    if revision != self.sentQueueRevision, self.controller?.send(queue) == true { self.sentQueueRevision = revision }
                } else { self.sentQueueRevision = "" }
            }
            self.status = self.phoneStatus.isEmpty ? self.music.status : self.phoneStatus + " · " + self.music.status
            self.render()
        }
    }
    private func requestArtwork() {
        if let request = artwork.request() { controller?.send(request) }
    }
    private func render() {
        checkContinuity()
        guard let phone, phone.fresh(), phoneEligible else { unpublish(); return }
        if !published { installCommands(); published = true }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: phone.title, MPMediaItemPropertyArtist: phone.artist,
            MPMediaItemPropertyAlbumTitle: phone.album, MPMediaItemPropertyPlaybackDuration: phone.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: phone.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: phone.playing ? 1.0 : 0.0]
        if let image = phoneArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = phone.playing ? .playing : .paused
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = phone.actions.contains("play")
        center.pauseCommand.isEnabled = phone.actions.contains("pause")
        center.togglePlayPauseCommand.isEnabled = phone.actions.contains(phone.playing ? "pause" : "play")
        center.nextTrackCommand.isEnabled = phone.actions.contains("next")
        center.previousTrackCommand.isEnabled = phone.actions.contains("previous")
        center.changePlaybackPositionCommand.isEnabled = phone.actions.contains("seek")
    }
    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, "play"), (center.pauseCommand, "pause"),
                                  (center.togglePlayPauseCommand, "toggle"), (center.nextTrackCommand, "next"),
                                  (center.previousTrackCommand, "previous"), (center.changePlaybackPositionCommand, "seek")] {
            let target = command.addTarget { [weak self] event in
                // MediaPlayer may invoke targets on another queue.
                let perform = { () -> MPRemoteCommandHandlerStatus in
                    self?.checkContinuity()
                    guard let self, self.enabled, self.subscribed, self.controller?.authenticated == true,
                          let phone = self.phone, phone.fresh(), self.phoneEligible else { return .commandFailed }
                    let resolved = action == "toggle" ? (phone.playing ? "pause" : "play") : action
                    guard phone.actions.contains(resolved) else { return .noActionableNowPlayingItem }
                    var value: [String: Any] = ["type": "mediaCommand", "id": phone.id, "action": resolved]
                    if let seek = event as? MPChangePlaybackPositionCommandEvent { value["position"] = seek.positionTime }
                    return self.controller?.send(value) == true ? .success : .commandFailed
                }
                return Thread.isMainThread ? perform() : DispatchQueue.main.sync(execute: perform)
            }
            targets.append((command, target))
        }
    }
    private func unpublish() {
        guard published else { return }
        targets.forEach { $0.0.removeTarget($0.1); $0.0.isEnabled = false }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        published = false
    }
    func clear() {
        lease.invalidate()
        wire = MediaStateWire()
        epoch += 1; sentQueueRevision = ""; subscribed = false; phoneStatus = ""; phone = nil; phoneArtwork = nil; artwork.clear(); music.clear(); unpublish()
    }
    deinit { if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) } }
    func stop() {
        controller?.send(["type": "mediaSubscribe", "enabled": false])
        clear(); timer?.invalidate(); timer = nil
    }
}
