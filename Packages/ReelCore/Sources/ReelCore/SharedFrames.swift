import Foundation

/// Frames taken from the videos, kept on the share in `.reel/frames` so each
/// one is read out of a video once for every phone, rather than once per
/// phone (and again after every reinstall). Taking a frame means VLC
/// streaming the file from the router; reading one back is a small JPEG.
///
/// One flat folder, so a single listing says which are there, and a frame
/// that isn't costs nothing to look for. Files are named by a hash of the
/// video's path, which is all a frame ref holds.
public enum SharedFrames {
    public static let folder = ".reel/frames"

    public static func path(for video: String) -> String { "\(folder)/\(name(for: video))" }

    /// FNV-1a, 64 bits: CryptoKit isn't on Linux, and a library's few
    /// thousand files are nowhere near colliding.
    public static func name(for video: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in video.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.jpg", hash)
    }

    /// Names of the frames already on the share. No folder yet means none.
    /// Anything half-written (a ".tmp") isn't a frame.
    public static func list(in storage: any ProgressStorage) async throws -> Set<String> {
        do {
            let entries = try await storage.list(folder)
            return Set(entries.filter { !$0.isDirectory && $0.name.hasSuffix(".jpg") }.map(\.name))
        } catch ShareError.folder {
            return []
        }
    }
}
