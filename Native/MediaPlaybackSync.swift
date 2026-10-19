import AppKit
import MediaPlayer

/// The background receiver is the sole owner of both Now Playing proxies.
final class MediaPlaybackSync {
    static let enabledKey = "DroidMirror.media.enabled"
    weak var controller: BLEController?
    private let music: AppleMusicAccess
    private var phone: MediaSnapshot?
    private var timer: Timer?
    private var targets = [(MPRemoteCommand, Any)]()
    private var published = false
    private var subscribed = false
    private var phoneStatus = ""
    private var epoch = 0
    private(set) var status = "Media syncing off"
    private var musicPlaying: Bool { music.snapshot.map { $0.fresh() && $0.playing } ?? false }
    private var enabled: Bool { NotificationRuntime.preferences.bool(forKey: Self.enabledKey) }

    init(music: AppleMusicAccess = AppleMusicSync()) {
        self.music = music
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
        case "mediaState": phone = MediaSnapshot(event); render()
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
        let generation = epoch
        music.poll { [weak self] value in
            guard let self, self.epoch == generation, self.enabled, self.subscribed,
                  self.controller?.authenticated == true else { return }
            var event = value; event["type"] = "mediaState"
            self.controller?.send(event)
            self.status = self.phoneStatus.isEmpty ? self.music.status : self.phoneStatus + " · " + self.music.status
            self.render()
        }
    }
    private func render() {
        guard let phone, phone.fresh(), !musicPlaying else { unpublish(); return }
        if !published { installCommands(); published = true }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: phone.title, MPMediaItemPropertyArtist: phone.artist,
            MPMediaItemPropertyAlbumTitle: phone.album, MPMediaItemPropertyPlaybackDuration: phone.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: phone.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: phone.playing ? 1.0 : 0.0]
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
                    guard let self, self.enabled, self.subscribed, self.controller?.authenticated == true,
                          let phone = self.phone, phone.fresh(), !self.musicPlaying else { return .commandFailed }
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
        epoch += 1; subscribed = false; phoneStatus = ""; phone = nil; music.clear(); unpublish()
    }
    func stop() {
        controller?.send(["type": "mediaSubscribe", "enabled": false])
        clear(); timer?.invalidate(); timer = nil
    }
}
