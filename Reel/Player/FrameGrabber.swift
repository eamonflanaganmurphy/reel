import Foundation
import ReelCore
import UIKit
import VLCKitSPM

/// Stills taken from the video files themselves, for anything TMDB and the
/// share have no poster or episode image for. VLC opens the file over SMB,
/// plays it muted from about a third of the way in and snapshots a frame.
///
/// Strictly one at a time, and held while a scan or playback is using the
/// share: the router is a small ARM box whose Samba has fallen over under
/// parallel reads before. Queued grabs whose view has scrolled away are
/// dropped when their turn comes rather than read.
@MainActor
final class FrameGrabber: NSObject {
    static let shared = FrameGrabber()

    /// Set while a scan or playback is running. Grabs already on screen stay
    /// queued and start once it clears.
    var paused = false {
        didSet { pump() }
    }

    private var running = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    /// Files VLC couldn't get a frame from this session, so a grid doesn't
    /// retry them on every scroll past.
    private var failed: Set<String> = []

    /// JPEG of a frame from the file at `path`, or nil if there isn't one to
    /// be had (or the caller stopped waiting).
    func jpeg(for path: String, config: SMBConfig) async -> Data? {
        guard !failed.contains(path), let url = config.playbackURL(for: path) else { return nil }
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in queue.append(turn); pump() }
        defer { running = false; pump() }
        guard !Task.isCancelled else { return nil }

        guard let frame = await Snapshot(url: url).take() else {
            failed.insert(path)
            return nil
        }
        return frame.jpegData(compressionQuality: 0.8)
    }

    private func pump() {
        guard !running, !paused, !queue.isEmpty else { return }
        running = true
        queue.removeFirst().resume()
    }
}

/// One frame from one file, through an ordinary muted VLCMediaPlayer.
///
/// Not VLCMediaThumbnailer: that forces FFmpeg's decoder, which can only do
/// AV1 in hardware VLC doesn't use, so every AV1 file (most of the YouTube
/// downloads) timed out there. A player picks decoders the way playback does.
@MainActor
private final class Snapshot: NSObject, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    /// VLC needs somewhere to draw before it will decode video. It's never
    /// shown; the snapshot comes from the decoded picture.
    private let view = UIView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("frame-\(UUID().uuidString).png")
    private var done: CheckedContinuation<UIImage?, Never>?
    private var seeked = false
    private var ticksSinceSeek = 0
    private var requestedAt: Date?

    init(url: URL) {
        super.init()
        let media = VLCMedia(url: url)
        media.addOption(":no-audio")
        media.addOption(":no-spu")
        media.addOption(":no-sub-autodetect-file")
        media.addOption(":network-caching=1500")
        player.media = media
        player.drawable = view
        player.delegate = self
    }

    func take() async -> UIImage? {
        await withCheckedContinuation { done in
            self.done = done
            player.play()
            // Covers files VLC can't open or decode, and a player that never
            // reports back, which would otherwise stall every grab after it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ image: UIImage?) {
        guard let done else { return }
        self.done = nil
        player.delegate = nil
        player.stop()
        try? FileManager.default.removeItem(at: file)
        done.resume(returning: image)
    }

    private func tick() {
        guard done != nil else { return }
        if !seeked {
            // Opening credits and black leaders are at the start. The length
            // is only known once playing; without one, take what's there.
            if (player.media?.length.intValue ?? 0) > 0 { player.position = 0.33 }
            seeked = true
            return
        }
        ticksSinceSeek += 1
        // A few ticks after the seek, so the picture is from after it.
        guard ticksSinceSeek >= 3, player.hasVideoOut else { return }
        // VLC drops a request it can't serve within half a second, so ask
        // again if nothing comes back.
        if let requestedAt, Date().timeIntervalSince(requestedAt) < 3 { return }
        requestedAt = Date()
        player.saveVideoSnapshot(at: file.path, withWidth: 640, andHeight: 0)
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in tick() }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            if [.error, .ended, .stopped].contains(player.state) { finish(nil) }
        }
    }

    nonisolated func mediaPlayerSnapshot(_ aNotification: Notification) {
        Task { @MainActor in
            // Read now: the file is deleted as soon as this finishes.
            let path = player.snapshots?.last as? String ?? file.path
            finish(FileManager.default.contents(atPath: path).flatMap(UIImage.init(data:)))
        }
    }
}
