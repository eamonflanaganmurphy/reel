import Combine
import Foundation
import UIKit
import VLCKitSPM

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Wraps VLCMediaPlayer and republishes what the controls need. VLC plays the
/// smb:// URL itself, so the router just serves bytes and nothing transcodes.
final class PlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let videoView = UIView()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var errorMessage: String?

    /// Called on the main thread when playback reaches the end.
    var onEnded: (() -> Void)?

    private var pendingSubtitles: [URL] = []
    private var hasStarted = false

    override init() {
        super.init()
        videoView.backgroundColor = .black
        player.drawable = videoView
        player.delegate = self
    }

    deinit {
        player.delegate = nil
        player.stop()
    }

    func load(_ url: URL, startAt seconds: Double) {
        let media = VLCMedia(url: url)
        // A bigger buffer than VLC's default: remote playback over the
        // router's uplink needs the headroom.
        media.addOption(":network-caching=3000")
        if seconds > 1 { media.addOption(":start-time=\(Int(seconds))") }
        pendingSubtitles = []
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
    func addSubtitles(_ urls: [URL]) {
        if hasStarted {
            for url in urls { _ = player.addPlaybackSlave(url, type: .subtitle, enforce: false) }
        } else {
            pendingSubtitles += urls
        }
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

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
        player.stop()
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
                for url in pendingSubtitles {
                    _ = player.addPlaybackSlave(url, type: .subtitle, enforce: false)
                }
                pendingSubtitles = []
            }
            refreshTracks()
        case .paused:
            isPlaying = false
        case .esAdded:
            refreshTracks()
        case .ended:
            isPlaying = false
            onEnded?()
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

    private func refreshTracks() {
        audioTracks = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        subtitleTracks = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        currentAudio = player.currentAudioTrackIndex
        currentSubtitle = player.currentVideoSubTitleIndex
    }

    private static func tracks(names: [Any], indexes: [Any]) -> [MediaTrack] {
        zip(indexes, names).compactMap { index, name in
            guard let id = (index as? NSNumber)?.int32Value else { return nil }
            return MediaTrack(id: id, name: (name as? String) ?? "Track \(id)")
        }
    }
}
