import AVFoundation
import Combine
import Foundation
import UIKit
import VLCKitSPM

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String

    static let subtitlesOff = MediaTrack(id: -1, name: "Off")
}

/// Wraps VLCMediaPlayer and republishes what the controls need. VLC plays the
/// smb:// URL itself, so the router just serves bytes and nothing transcodes.
final class PlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    /// Goes in the SwiftUI hierarchy. VLC draws into `drawable` inside it.
    let videoView = UIView()
    /// VLC adds a tap recognizer (for DVD menus) to its drawable's *superview*.
    /// Handing it SwiftUI's view directly let that recognizer steal every tap,
    /// so it gets a child of our own, touch-disabled container instead.
    private let drawable = UIView()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
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

    private var pendingSubtitles: [Sidecar] = []
    /// Labels of sidecars handed to VLC whose tracks haven't appeared yet.
    /// VLC opens them in order, so they're matched to new track ids in order.
    private var unmatchedLabels: [String] = []
    private var subtitleLabels: [Int32: String] = [:]
    private var seenSubtitleIDs: Set<Int32> = []
    private var hasStarted = false

    override init() {
        super.init()
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        drawable.frame = videoView.bounds
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        drawable.backgroundColor = .black
        videoView.addSubview(drawable)
        player.drawable = drawable
        player.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioRouteChanged(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(audioInterrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// Headphones unplugged, out of Bluetooth range or taken out of the
    /// ears: pause, as every iOS player does, rather than carry on out of the
    /// speaker (on a plane, say).
    @objc private func audioRouteChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.pauseIfPlaying() }
    }

    /// A call or an alarm took the audio. Playback waits for the user after.
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async { [weak self] in self?.pauseIfPlaying() }
    }

    private func pauseIfPlaying() {
        if player.isPlaying { player.pause() }
    }

    deinit {
        player.delegate = nil
        player.stopInBackground()
    }

    func load(_ url: URL, startAt seconds: Double) {
        let media = VLCMedia(url: url)
        // A bigger buffer than VLC's default: remote playback over the
        // router's uplink needs the headroom.
        media.addOption(":network-caching=3000")
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
        currentTime = seconds
        duration = 0
        isBuffering = true
        player.media = media
        player.play()
    }

    /// Sidecar subtitles, downloaded to local files. Safe to call before the
    /// file has opened; they attach once it has.
    func addSubtitles(_ sidecars: [Sidecar]) {
        if hasStarted {
            attach(sidecars)
        } else {
            pendingSubtitles += sidecars
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
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func pause() { player.pause() }
    func play() { player.play() }

    func skip(_ seconds: Int32) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    func stop() {
        player.stopInBackground()
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.stateChanged() }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = Double(self.player.time.intValue) / 1000
            if abs(t - self.currentTime) >= 0.5 { self.currentTime = t }
            if self.duration == 0, let length = self.player.media?.length.intValue, length > 0 {
                self.duration = Double(length) / 1000
            }
            if self.isBuffering { self.isBuffering = false }
            // VLC doesn't always report .playing after buffering.
            if self.player.isPlaying, !self.isPlaying { self.isPlaying = true }
        }
    }

    private func stateChanged() {
        switch player.state {
        case .opening, .buffering:
            isBuffering = !player.isPlaying
        case .playing:
            isBuffering = false
            isPlaying = true
            if !hasStarted {
                hasStarted = true
                // Slaves only attach once the input is open.
                let pending = pendingSubtitles
                pendingSubtitles = []
                attach(pending)
            }
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
                onEnded?()
            } else {
                // VLC also "ends" a stream the router stopped sending partway,
                // which mustn't mark the video watched and skip to the next.
                errorMessage = "Lost the connection to the share. Check the server is reachable, then try again."
            }
        case .error:
            isPlaying = false
            isBuffering = false
            errorMessage = "VLC couldn't open this file. Check the server is reachable, then try again."
        case .stopped:
            isPlaying = false
        @unknown default:
            break
        }
        if let length = player.media?.length.intValue, length > 0 { duration = Double(length) / 1000 }
    }

    /// Near enough the end to count as finished, by the same rule that
    /// marks a video watched. With no length known there's no telling.
    private var reachedEnd: Bool {
        guard duration > 0 else { return true }
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
    }

    private static func tracks(names: [Any], indexes: [Any]) -> [MediaTrack] {
        zip(indexes, names).compactMap { index, name in
            guard let id = (index as? NSNumber)?.int32Value else { return nil }
            return MediaTrack(id: id, name: (name as? String) ?? "Track \(id)")
        }
    }
}

extension VLCMediaPlayer {
    /// VLCKit 3's `stop` waits for VLC's input thread to finish, which can
    /// take as long as an SMB read takes to time out. Off the main thread, a
    /// stalled share can't freeze the app. One queue, so stops never overlap.
    func stopInBackground() {
        VLCMediaPlayer.stopQueue.async { self.stop() }
    }

    private static let stopQueue = DispatchQueue(label: "Reel.VLCStop", qos: .userInitiated)
}
