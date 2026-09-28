import Foundation
import ReelCore
import UIKit
import VLCKitSPM

/// Stills taken from the video files themselves, for anything TMDB and the
/// share have no poster or episode image for. VLC opens the file over SMB,
/// seeks about a third of the way in and hands back one frame.
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
    private var current: (thumbnailer: VLCMediaThumbnailer, done: CheckedContinuation<CGImage?, Never>)?
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

        let frame: CGImage? = await withCheckedContinuation { done in
            let thumbnailer = VLCMediaThumbnailer(media: VLCMedia(url: url), andDelegate: self)
            // An upper bound; VLC keeps the video's own aspect ratio inside it.
            thumbnailer.thumbnailWidth = 640
            thumbnailer.thumbnailHeight = 360
            current = (thumbnailer, done)
            thumbnailer.fetchThumbnail()
            // VLC has its own timeouts; this is in case a callback never
            // comes, which would otherwise stall every grab after it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(70))
                self?.finish(thumbnailer, frame: nil)
            }
        }
        guard let frame else {
            failed.insert(path)
            return nil
        }
        return UIImage(cgImage: frame).jpegData(compressionQuality: 0.8)
    }

    private func pump() {
        guard !running, !paused, !queue.isEmpty else { return }
        running = true
        queue.removeFirst().resume()
    }

    private func finish(_ thumbnailer: VLCMediaThumbnailer, frame: CGImage?) {
        guard let current, current.thumbnailer === thumbnailer else { return }
        self.current = nil
        current.done.resume(returning: frame)
    }
}

// The timeout covers files VLC can't open or decode, after up to 10s parsing
// plus 45s waiting for a frame.
extension FrameGrabber: VLCMediaThumbnailerDelegate {
    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        Task { @MainActor in finish(mediaThumbnailer, frame: thumbnail) }
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor in finish(mediaThumbnailer, frame: nil) }
    }
}
