import AppKit
import MediaPlayer
import IOKit

/// The background receiver is the sole owner of both Now Playing proxies.
final class MediaPlaybackSync {
    static let enabledKey = "DroidMirror.media.enabled"
    static let volumeKeysKey = "DroidMirror.media.volumeKeys"
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
    private var observers = [(NotificationCenter, NSObjectProtocol)]()
    private var asleep = false
    private var screenAsleep = false
    private var stopped = false
    private var schedule = MusicPollSchedule()
    private var refreshQueued = false
    private var pendingCommand: [String: Any]?
    private var lastPublication: String?
    private var phoneArtworkSource: String?
    private var targets = [(MPRemoteCommand, Any)]()
    private var published = false
    private var subscribed = false
    private var phoneStatus = ""
    private var sentQueueRevision = ""
    private var wire = MediaStateWire()
    private var epoch = 0
    private(set) var status = "Media syncing off"
    private var enabled: Bool { NotificationRuntime.preferences.bool(forKey: Self.enabledKey) }
    private let volumeKeys = PhoneVolumeKeyTap()
    private let volumeHUD = PhoneVolumeHUD()
    private var phoneVolume: PhoneVolumeState?
    private var volumePressedAt = -Double.infinity
    private var volumeKeysWanted: Bool {
        guard published, NotificationRuntime.preferences.bool(forKey: Self.volumeKeysKey),
              let phone, phone.volumeControl else { return false }
        return true
    }

    init(music: AppleMusicAccess = AppleMusicSync()) {
        self.music = music
        volumeKeys.onPress = { [weak self] action in self?.sendVolume(action) }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lease.invalidate(); self.render()
            self.asleep = true
            self.timer?.invalidate(); self.timer = nil
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            guard let self else { return }
            self.asleep = false
            self.startTimer()
            self.schedule.requestSoon(); self.tick()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.screenAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.screenAsleep = false; self?.refreshMusicSoon() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == "com.apple.Music" { self?.refreshMusicSoon() }
            }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.Music.playerInfo")) { [weak self] _ in self?.refreshMusicSoon() }
        startTimer()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }
    private func startTimer() {
        guard timer == nil, !stopped else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Coalesces bursts of change signals into a single read.
    private func refreshMusicSoon() {
        schedule.requestSoon()
        guard !refreshQueued, !asleep else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshQueued = false
            self?.tick()
        }
    }
    private func updatePhoneArtwork(_ source: String?) {
        // Keeping the same image object also keeps Now Playing from being republished.
        guard source != phoneArtworkSource else { return }
        phoneArtworkSource = source
        phoneArtwork = MediaArtwork.decode(source)
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
        case "mediaClockChanged":
            wire.refreshTiming(); refreshMusicSoon()
        case "mediaState":
            guard let event = wire.receive(event) else { return }
            checkContinuity()
            phone = MediaSnapshot(event, sessionScoped: wire.peerSupportsLocalTimeline)
            lease.observe(phone, now: ProcessInfo.processInfo.systemUptime)
            artwork.observe(phone == nil ? [:] : event)
            updatePhoneArtwork(phone == nil ? nil : artwork.completed ?? (event["artwork"] as? String))
            requestArtwork()
            render()
            if wire.needsAcknowledgment { refreshMusicSoon() }
        case "mediaArtworkRequest":
            // The transfer is bound to the advertised digest, not to how recently Music was read.
            if music.snapshot != nil, let reply = artwork.reply(event) { controller?.send(reply) }
        case "mediaArtworkChunk":
            guard phone?.fresh() == true, artwork.receive(event) else { return }
            updatePhoneArtwork(artwork.completed)
            requestArtwork(); render()
        case "mediaCommand":
            // Reads are no longer continuous. Keep the requirement that a command
            // acts on a fresh snapshot by reading first when the last one has aged.
            if music.snapshot?.fresh() == true { music.command(event); refreshMusicSoon() }
            else { pendingCommand = event; schedule.requestSoon(); tick() }
        case "mediaVolumeState":
            guard let state = PhoneVolumeState(event, expectedID: phone?.id) else { return }
            phoneVolume = state
            // Only key presses on this Mac present the HUD; phone-side changes stay silent.
            if ProcessInfo.processInfo.systemUptime - volumePressedAt < 2 { volumeHUD.show(state) }
        case "mediaStatus": phoneStatus = event["message"] as? String ?? "Phone media unavailable"
        default: break
        }
    }
    private func tick() {
        guard !asleep else { return }
        guard enabled, subscribed, controller?.authenticated == true else {
            clear()
            status = enabled ? "Waiting for a paired phone with media support" : "Media syncing off"
            return
        }
        render()
        if phone?.fresh() == true { requestArtwork() }
        let started = ProcessInfo.processInfo.systemUptime
        guard schedule.due(now: started) else { return }
        schedule.begin(now: started)
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
            if self.volumeKeys.needsPermission, NotificationRuntime.preferences.bool(forKey: Self.volumeKeysKey) {
                self.status += " · Allow DroidMirror Notifications in Accessibility for phone volume keys"
            }
            self.schedule.finish(now: ProcessInfo.processInfo.systemUptime, interval: MusicPollSchedule.interval(
                localTimeline: self.wire.peerSupportsLocalTimeline, playing: self.music.snapshot?.playing == true,
                screenAwake: !self.screenAsleep))
            if let command = self.pendingCommand {
                self.pendingCommand = nil
                self.music.command(command)
                self.schedule.requestSoon()
            }
            self.render()
            if self.schedule.soon { self.refreshMusicSoon() }
        }
    }
    private func requestArtwork() {
        if let request = artwork.request() { controller?.send(request) }
    }
    private func updateVolumeKeys() {
        let wanted = volumeKeysWanted
        volumeKeys.retryIfPermitted(wanted)
        volumeKeys.setActive(wanted)
        if !wanted { volumeHUD.hide() }
    }
    private func sendVolume(_ action: String) {
        checkContinuity()
        guard enabled, subscribed, controller?.authenticated == true, volumeKeysWanted,
              let phone, phone.fresh(), phoneEligible else { updateVolumeKeys(); return }
        guard controller?.send(["type": "mediaVolume", "id": phone.id, "action": action]) == true else { return }
        volumePressedAt = ProcessInfo.processInfo.systemUptime
        if let state = phoneVolume, state.id == phone.id {
            phoneVolume = state.predicting(action); volumeHUD.show(phoneVolume!)
        }
    }
    private func render() {
        checkContinuity()
        defer { updateVolumeKeys() }
        guard let phone, phone.fresh(), phoneEligible else { unpublish(); return }
        if phoneVolume?.id != phone.id { phoneVolume = nil }
        if !published { installCommands(); published = true }
        let publication = phone.publicationKey + (phoneArtwork.map { "\(ObjectIdentifier($0))" } ?? "")
        guard publication != lastPublication else { return }
        lastPublication = publication
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: phone.title, MPMediaItemPropertyArtist: phone.artist,
            MPMediaItemPropertyAlbumTitle: phone.album, MPMediaItemPropertyPlaybackDuration: phone.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: phone.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: phone.rate]
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
        lastPublication = nil
        phoneVolume = nil
        updateVolumeKeys()
    }
    func clear() {
        lease.invalidate()
        wire = MediaStateWire()
        schedule.reset(); pendingCommand = nil
        epoch += 1; sentQueueRevision = ""; subscribed = false; phoneStatus = ""; phone = nil; phoneArtwork = nil; phoneArtworkSource = nil; artwork.clear(); music.clear(); unpublish()
    }
    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        observers.forEach { $0.0.removeObserver($0.1) }
    }
    func stop() {
        stopped = true
        controller?.send(["type": "mediaSubscribe", "enabled": false])
        clear(); volumeKeys.stop(); timer?.invalidate(); timer = nil
    }
}
