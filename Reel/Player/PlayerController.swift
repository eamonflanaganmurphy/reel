import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit
import VLCKitSPM

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String

    static let subtitlesOff = MediaTrack(id: -1, name: "Off")
}

/// Wraps VLCMediaPlayer and republishes what the controls need. VLC plays the
/// smb:// or http(s):// URL itself, so the router just serves bytes and nothing transcodes.
///
/// When the share stops sending partway (the router's WiFi drops for a few
/// seconds, say), what's buffered plays on and then the file is opened again
/// where it got to, over and over for a while, before it's called lost.
final class PlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    /// A new one for each file opened. Telling a player stuck on a stalled
    /// share to open something else blocks until its read times out, so the
    /// old one is stopped and let go in the background instead (see
    /// `stopInBackground`).
    private(set) var player = VLCMediaPlayer()
    /// Goes in the SwiftUI hierarchy. VLC draws into `drawable` inside it.
    let videoView = UIView()
    /// VLC adds a tap recognizer (for DVD menus) to its drawable's *superview*.
    /// Handing it SwiftUI's view directly let that recognizer steal every tap,
    /// so it gets a child of our own, touch-disabled container instead.
    private var drawable = UIView()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    /// The share went quiet and the file is being opened again.
    @Published private(set) var isReconnecting = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = [.subtitlesOff]
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var errorMessage: String?

    /// Called on the main thread when playback reaches the end.
    var onEnded: (() -> Void)?

    /// A subtitle file on this phone, waiting to be handed to VLC.
    struct Sidecar {
        let url: URL
        /// Shown in the menu. VLC only calls a sidecar "Track 3".
        let label: String
        /// Switch to it once attached, for one the user just added.
        var select = false
    }

    private var url: URL?
    private var pendingSubtitles: [Sidecar] = []
    /// Every sidecar handed over for this file, to hand over again when
    /// it's reopened.
    private var sidecars: [Sidecar] = []
    /// Labels of sidecars handed to VLC whose tracks haven't appeared yet.
    /// VLC opens them in order, so they're matched to new track ids in order.
    private var unmatchedLabels: [String] = []
    private var subtitleLabels: [Int32: String] = [:]
    private var seenSubtitleIDs: Set<Int32> = []
    private var hasStarted = false
    /// The tracks that were on before a reconnect, by name, until they're
    /// back to pick again. Ids can change when a file is reopened.
    private var restoreAudio: String?
    private var restoreSubtitle: String?

    /// Whether the user wants it playing, as opposed to paused. A stall only
    /// counts when it should be playing.
    private var wantsToPlay = false
    /// When playback last moved on, or the file was last opened.
    private var lastProgress = Date()
    private var watchdog: Timer?
    private var reconnectAttempts = 0
    private var reconnectStarted: Date?
    private var reconnectWork: DispatchWorkItem?

    /// How far ahead VLC reads a file on the share, in milliseconds. A
    /// dropout shorter than this doesn't interrupt the picture.
    private static let networkCaching = 10_000
    /// No progress for this long while it should be playing, with nothing
    /// left buffered, is taken as the share having gone quiet. VLC can
    /// otherwise wait on a dead connection for minutes.
    private static let stallTimeout: TimeInterval = 15
    /// Opening a file gets longer before it counts as stuck.
    private static let openTimeout: TimeInterval = 25
    /// How long to keep reopening a file that's lost before giving up.
    private static let reconnectWindow: TimeInterval = 120

    override init() {
        super.init()
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        install(drawable)
        player.drawable = drawable
        player.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioRouteChanged(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(audioInterrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
    }

    private func install(_ view: UIView) {
        view.frame = videoView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .black
        videoView.addSubview(view)
    }

    /// Headphones unplugged, out of Bluetooth range or taken out of the
    /// ears: pause, as every iOS player does, rather than carry on out of the
    /// speaker (on a plane, say).
    @objc private func audioRouteChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.pause() }
    }

    /// A call or an alarm took the audio. Playback waits for the user after.
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async { [weak self] in self?.pause() }
    }

    deinit {
        watchdog?.invalidate()
        reconnectWork?.cancel()
        player.delegate = nil
        player.stopInBackground()
    }

    func load(_ url: URL, startAt seconds: Double) {
        self.url = url
        sidecars = []
        restoreAudio = nil
        restoreSubtitle = nil
        reconnectAttempts = 0
        reconnectStarted = nil
        duration = 0
        open(startAt: seconds)
    }

    /// Opens `url` in a fresh player, from `seconds`.
    private func open(startAt seconds: Double) {
        guard let url else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        replacePlayer()

        let media = VLCMedia(url: url)
        if !url.isFileURL {
            // Far more than VLC's default second, so the picture rides out
            // the share going quiet for a few seconds.
            media.addOption(":network-caching=\(Self.networkCaching)")
        }
        if seconds > 1 { media.addOption(":start-time=\(Int(seconds))") }
        pendingSubtitles = []
        unmatchedLabels = []
        subtitleLabels = [:]
        seenSubtitleIDs = []
        subtitleTracks = [.subtitlesOff]
        audioTracks = []
        currentSubtitle = -1
        hasStarted = false
        errorMessage = nil
        // The length stays put through a reconnect, so the bar doesn't jump.
        currentTime = seconds
        isBuffering = true
        wantsToPlay = true
        lastProgress = Date()
        player.media = media
        player.play()
        startWatchdog()
        // Sidecars from before a reconnect go back on once it's open.
        addSubtitles(sidecars.map { Sidecar(url: $0.url, label: $0.label) }, remember: false)
    }

    private func replacePlayer() {
        guard player.media != nil else { return }
        let old = player
        old.delegate = nil
        old.stopInBackground()
        drawable.removeFromSuperview()
        drawable = UIView()
        install(drawable)
        player = VLCMediaPlayer()
        player.drawable = drawable
        player.delegate = self
        isPlaying = false
    }

    /// Sidecar subtitles, downloaded to local files. Safe to call before the
    /// file has opened; they attach once it has.
    func addSubtitles(_ new: [Sidecar]) {
        addSubtitles(new, remember: true)
    }

    private func addSubtitles(_ new: [Sidecar], remember: Bool) {
        guard !new.isEmpty else { return }
        if remember { sidecars += new }
        if hasStarted {
            attach(new)
        } else {
            pendingSubtitles += new
        }
    }

    private func attach(_ sidecars: [Sidecar]) {
        guard !sidecars.isEmpty else { return }
        // Know which tracks were there before, so the new ones get the labels.
        refreshTracks()
        for s in sidecars {
            if player.addPlaybackSlave(s.url, type: .subtitle, enforce: s.select) == 0 {
                unmatchedLabels.append(s.label)
            }
        }
        // VLC opens slaves on its own thread and doesn't say when a track
        // is selected, only when one is added.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshTracks() }
        }
    }

    func togglePlay() {
        if wantsToPlay { pause() } else { play() }
    }

    func pause() {
        wantsToPlay = false
        if isReconnecting {
            // Nothing to pause yet; it's opened again when the user says.
            reconnectWork?.cancel()
            reconnectWork = nil
            isReconnecting = false
            isBuffering = false
        }
        if player.isPlaying || player.state == .buffering || player.state == .opening { player.pause() }
        isPlaying = false
        updateNowPlaying()
    }

    func play() {
        wantsToPlay = true
        lastProgress = Date()
        if player.media == nil || player.state == .ended || player.state == .error || player.state == .stopped {
            // Paused while it was reconnecting, or it had been lost.
            reconnect()
        } else {
            player.play()
        }
        updateNowPlaying()
    }

    func skip(_ seconds: Int32) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
        lastProgress = Date()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        lastProgress = Date()
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
        updateNowPlaying()
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
        restoreAudio = nil
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
        restoreSubtitle = nil
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        wantsToPlay = false
        player.stopInBackground()
        clearNowPlaying()
    }

    // MARK: Reconnecting

    private func startWatchdog() {
        guard watchdog == nil, url.map({ !$0.isFileURL }) == true else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkForStall()
        }
    }

    private func checkForStall() {
        // Waiting to reopen is a stall already being dealt with; a reopen
        // that hangs is one more.
        guard wantsToPlay, reconnectWork == nil, errorMessage == nil, url.map({ !$0.isFileURL }) == true else { return }
        let limit = hasStarted ? Self.stallTimeout : Self.openTimeout
        if Date().timeIntervalSince(lastProgress) > limit { connectionLost() }
    }

    /// The share stopped sending, or VLC gave up on it. Opens the file
    /// again where it got to, waiting longer each time, until it plays or
    /// it's been trying too long.
    private func connectionLost() {
        guard let url, !url.isFileURL else {
            errorMessage = "VLC couldn't open this file."
            return
        }
        let started = reconnectStarted ?? Date()
        reconnectStarted = started
        guard Date().timeIntervalSince(started) < Self.reconnectWindow else {
            giveUp()
            return
        }
        if hasStarted {
            // Pick the same tracks again once they're back.
            restoreAudio = restoreAudio ?? audioTracks.first { $0.id == currentAudio }?.name
            restoreSubtitle = restoreSubtitle ?? subtitleTracks.first { $0.id == currentSubtitle }?.name
        }
        isReconnecting = true
        isBuffering = true
        isPlaying = false
        let delay = min(8, pow(2, Double(reconnectAttempts)))
        reconnectAttempts += 1
        // Stop the stuck one now, so it doesn't jump back in later.
        replacePlayer()
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reconnect() {
        let resumeAt = currentTime
        open(startAt: resumeAt)
        // `open` clears this; it's still the same reconnect until it plays.
        isReconnecting = reconnectStarted != nil
    }

    private func giveUp() {
        isReconnecting = false
        isBuffering = false
        isPlaying = false
        wantsToPlay = false
        reconnectAttempts = 0
        reconnectStarted = nil
        replacePlayer()
        errorMessage = "Lost the connection to the share. Check the server is reachable, then try again."
        updateNowPlaying()
    }

    /// It's playing again, so a later dropout starts its own count.
    private func recovered() {
        guard reconnectStarted != nil || isReconnecting else { return }
        reconnectStarted = nil
        reconnectAttempts = 0
        isReconnecting = false
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.stateChanged(aNotification.object as? VLCMediaPlayer) }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A player let go for a reconnect can still report in.
            if let sender = aNotification.object as? VLCMediaPlayer, sender !== self.player { return }
            let t = Double(self.player.time.intValue) / 1000
            if abs(t - self.currentTime) >= 0.5 {
                self.currentTime = t
                if Int(t) % 10 == 0 { self.updateNowPlaying() }
            }
            self.lastProgress = Date()
            if self.duration == 0, let length = self.player.media?.length.intValue, length > 0 {
                self.duration = Double(length) / 1000
                self.updateNowPlaying()
            }
            if self.isBuffering { self.isBuffering = false }
            // VLC doesn't always report .playing after buffering, and a local
            // file can be playing before the async state callbacks catch up,
            // which left its tracks unlisted.
            if self.player.isPlaying {
                self.started()
                if !self.isPlaying {
                    self.isPlaying = true
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func stateChanged(_ sender: VLCMediaPlayer?) {
        // A player let go for a reconnect can still report in.
        if let sender, sender !== player { return }
        switch player.state {
        case .opening, .buffering:
            isBuffering = !player.isPlaying
            if player.isPlaying { started() }
        case .playing:
            isBuffering = false
            isPlaying = true
            started()
            refreshTracks()
        case .paused:
            isPlaying = false
        case .esAdded:
            refreshTracks()
        case .ended:
            isPlaying = false
            isBuffering = false
            // Time updates are throttled; take the last position VLC has, so
            // progress saved from here agrees with the check below.
            let last = Double(player.time.intValue) / 1000
            if last > currentTime { currentTime = last }
            if reachedEnd {
                wantsToPlay = false
                onEnded?()
            } else {
                // VLC also "ends" a stream the router stopped sending partway,
                // which mustn't mark the video watched and skip to the next.
                connectionLost()
            }
        case .error:
            isPlaying = false
            isBuffering = false
            if url?.isFileURL == true {
                errorMessage = "VLC couldn't open this file."
            } else {
                connectionLost()
            }
        case .stopped:
            isPlaying = false
        @unknown default:
            break
        }
        if let length = player.media?.length.intValue, length > 0 { duration = Double(length) / 1000 }
        updateNowPlaying()
    }

    /// The file is open and playing: hand over sidecars waiting for that.
    private func started() {
        recovered()
        guard !hasStarted else { return }
        hasStarted = true
        // Slaves only attach once the input is open.
        let pending = pendingSubtitles
        pendingSubtitles = []
        attach(pending)
        refreshTracks()
        // Embedded tracks can be listed a moment after it starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshTracks() }
    }

    /// Near enough the end to count as finished, by the same rule that
    /// marks a video watched. With no length known there's no telling.
    private var reachedEnd: Bool {
        guard duration > 0 else { return url?.isFileURL ?? true }
        return Video.isFinished(position: currentTime, duration: duration)
    }

    private func refreshTracks() {
        audioTracks = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        currentAudio = player.currentAudioTrackIndex
        currentSubtitle = player.currentVideoSubTitleIndex

        let subs = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
            .filter { $0.id >= 0 }
        for id in subs.map(\.id).filter({ !seenSubtitleIDs.contains($0) }).sorted() {
            seenSubtitleIDs.insert(id)
            if !unmatchedLabels.isEmpty { subtitleLabels[id] = unmatchedLabels.removeFirst() }
        }
        // VLC's own "Disable" entry only exists once there's a track, so
        // "Off" is always added here instead.
        subtitleTracks = [.subtitlesOff]
            + subs.map { MediaTrack(id: $0.id, name: subtitleLabels[$0.id] ?? $0.name) }
        restoreTracks()
    }

    /// After a reconnect, the audio and subtitles that were on before.
    private func restoreTracks() {
        guard hasStarted else { return }
        if let name = restoreAudio, let track = audioTracks.first(where: { $0.name == name }) {
            restoreAudio = nil
            if track.id != currentAudio {
                player.currentAudioTrackIndex = track.id
                currentAudio = track.id
            }
        }
        if let name = restoreSubtitle, let track = subtitleTracks.first(where: { $0.name == name }) {
            restoreSubtitle = nil
            if track.id != currentSubtitle {
                player.currentVideoSubTitleIndex = track.id
                currentSubtitle = track.id
            }
        }
    }

    private static func tracks(names: [Any], indexes: [Any]) -> [MediaTrack] {
        zip(indexes, names).compactMap { index, name in
            guard let id = (index as? NSNumber)?.int32Value else { return nil }
            return MediaTrack(id: id, name: (name as? String) ?? "Track \(id)")
        }
    }

    // MARK: System controls

    /// What the lock screen, Control Center and headphones show and
    /// control. Set by the screen as each video starts.
    struct NowPlaying {
        var title: String
        var subtitle: String?
        var artwork: UIImage?
    }

    var nowPlaying: NowPlaying? {
        didSet { updateNowPlaying() }
    }

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    /// Takes the play, pause and skip buttons on the lock screen, in
    /// Control Center and on headphones and AirPods.
    func enableSystemControls() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Bool) {
            command.isEnabled = true
            let target = command.addTarget { handler($0) ? .success : .commandFailed }
            remoteTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in self?.play(); return self != nil }
        on(center.pauseCommand) { [weak self] _ in self?.pause(); return self != nil }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay(); return self != nil }
        center.skipForwardCommand.preferredIntervals = [30]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(30); return self != nil }
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(-10); return self != nil }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
            self.seek(to: event.positionTime)
            return true
        }
    }

    private func clearNowPlaying() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func updateNowPlaying() {
        guard let nowPlaying, !remoteTargets.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let subtitle = nowPlaying.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let image = nowPlaying.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

extension VLCMediaPlayer {
    /// Stops the player for good and lets it go, never on the main thread.
    ///
    /// VLCKit 3's `stop` only asks VLC to stop (libvlc_media_player_stop_async):
    /// the file is closed on a thread of VLC's, which on a stalled share takes as
    /// long as an SMB read takes to time out. Freeing the player waits for that
    /// thread, and the video output it's closing waits for the main thread, so
    /// a player freed on the main thread meanwhile deadlocks the app until iOS
    /// kills it. VLCKit's own callbacks to the main thread hold the player too
    /// and could be the last to let go, so it's kept here until VLC says it has
    /// stopped and those callbacks have run, then released on a background queue.
    func stopInBackground() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { RetiredPlayer.retire(self) }
        } else {
            DispatchQueue.main.async { RetiredPlayer.retire(self) }
        }
    }
}

/// Holds a stopped player until VLC has finished with it. See `stopInBackground`.
@MainActor
private final class RetiredPlayer: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    private static var all: [ObjectIdentifier: RetiredPlayer] = [:]

    private let id: ObjectIdentifier
    private var player: VLCMediaPlayer?
    private var drawable: Any?

    private init(_ player: VLCMediaPlayer) {
        id = ObjectIdentifier(player)
        self.player = player
        drawable = player.drawable
    }

    static func retire(_ player: VLCMediaPlayer) {
        let id = ObjectIdentifier(player)
        guard all[id] == nil else { return }
        let retired = RetiredPlayer(player)
        all[id] = retired
        player.delegate = retired
        player.stop()
        // One that never reports stopping, e.g. it had already ended. VLC is
        // long done with it by then.
        Task {
            try? await Task.sleep(for: .seconds(60))
            retired.release()
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            guard let state = player?.state, state == .stopped || state == .error else { return }
            release()
        }
    }

    private func release() {
        guard Self.all.removeValue(forKey: id) != nil, let player else { return }
        player.delegate = nil
        self.player = nil
        let drawable = drawable
        self.drawable = nil
        let box = Box(player: player, drawable: drawable)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            // Lets every callback VLCKit queued for the main thread run first,
            // so this is normally the last reference.
            DispatchQueue.main.sync {}
            box.player = nil
            // A view is only freed on the main thread.
            DispatchQueue.main.async { box.drawable = nil }
        }
    }

    private final class Box: @unchecked Sendable {
        var player: VLCMediaPlayer?
        var drawable: Any?

        init(player: VLCMediaPlayer, drawable: Any?) {
            self.player = player
            self.drawable = drawable
        }
    }
}
