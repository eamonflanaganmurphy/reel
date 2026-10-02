import Foundation

/// Copies a video from the share onto the device a piece at a time, adding
/// each to a partial file. A download that stops partway (the app was put
/// away, the phone left the WiFi, a video started playing) carries on from
/// the end of that file the next time, rather than starting again.
public enum FileDownload {
    /// Small enough that the share's other requests (posters, progress)
    /// never wait long behind a piece.
    public static let pieceSize: UInt64 = 4 << 20

    /// Reads the file into `partial` from wherever it got to, until a read
    /// comes back short, which is the end of the file. Returns its size.
    /// `progress` gets the bytes so far after each piece. Cancelling the
    /// task stops it between pieces, keeping what it has.
    @discardableResult
    public static func fetch(
        into partial: URL,
        pieceSize: UInt64 = pieceSize,
        read: @Sendable (Range<UInt64>) async throws -> Data,
        progress: @Sendable (Int64) async -> Void = { _ in }
    ) async throws -> Int64 {
        let files = FileManager.default
        if !files.fileExists(atPath: partial.path) {
            guard files.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        await progress(Int64(offset))
        while true {
            try Task.checkCancellation()
            let piece = try await read(offset..<offset + pieceSize)
            if !piece.isEmpty {
                try handle.write(contentsOf: piece)
                offset += UInt64(piece.count)
                await progress(Int64(offset))
            }
            if UInt64(piece.count) < pieceSize { return Int64(offset) }
        }
    }
}
