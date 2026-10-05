import CryptoKit
import Foundation
import Observation
import ReelCore
import SwiftData
import UIKit

/// Videos copied from the share onto this device, to watch with no way to
/// reach it: in the car, or anywhere away from the router. Each goes in its
/// own folder under Application Support with its subtitle files, out of
/// iCloud backups.
///
/// Up to four run at once, each a piece at a time (see `FileDownload`)
/// over a connection of its own, and they carry on while a video plays. A
/// scan pauses them, and each picks up from where it got to once the scan is
/// done, as it does after the app has been put away.
@MainActor
@Observable
final class DownloadCenter {
    struct Item: Codable, Identifiable, Equatable {
        /// The video's path in the share.
        let path: String
        /// From the last scan, for the progress bar; the real size once finished.
        var size: Int64
        var subtitles: [SubtitleFile]
        var addedAt: Date
        var finished = false
        /// Why it stopped, until it's tried again.
        var failure: String?

        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }
    }

    enum State: Equatable {
        case notDownloaded
        /// Waiting for its turn, or for the router to be free.
        case queued
        /// How far it's got, if the size is known.
        case downloading(Double?)
        case failed(String)
        case downloaded
    }

    /// In the order they were asked for, which is the order they download.
    private(set) var items: [Item] = [] {
        didSet { save() }
    }
    /// Bytes so far of each one downloading, by path.
    private(set) var received: [String: Int64] = [:]
    /// Why the queue has stopped, e.g. the share is out of reach. Cleared
    /// when the app comes back to the front, or by Try Again.
    private(set) var stopReason: String?

    /// Set while a scan is using the router. Downloads under way stop and
    /// carry on after.
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused { cancelAll() } else { pump() }
        }
    }

    var isDownloading: Bool { !workers.isEmpty }

    /// How many run at once.
    static let maxConcurrent = 4

    /// Paths of the videos downloaded in full, which scans keep in the
    /// library even once they're gone from the share.
    var finishedPaths: Set<String> { Set(items.filter(\.finished).map(\.path)) }

    /// Bytes on this device in finished downloads.
    var bytesOnDevice: Int64 { items.filter(\.finished).reduce(0) { $0 + $1.size } }

    private weak var settings: AppSettings?
    /// The downloads under way, by path.
    private var workers: [String: Task<Void, Never>] = [:]
    /// The app was put away and its time to finish in the background ran
    /// out. The queue waits for it to come back.
    private var suspended = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static var root: URL { DownloadFiles.root }

    private static var index: URL { root.appendingPathComponent("index.json") }

    init() {
        let files = FileManager.default
        try? files.createDirectory(at: Self.root, withIntermediateDirectories: true)
        // Gigabytes of video the share already has don't belong in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = Self.root
        try? root.setResourceValues(values)

        let saved = (try? Data(contentsOf: Self.index)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        // Anything finished whose file has gone, e.g. a restore from backup.
        items = saved.filter { !$0.finished || files.fileExists(atPath: Self.file(for: $0).path) }
    }

    /// Starts the queue once the settings are known, at launch.
    func start(settings: AppSettings) {
        self.settings = settings
        pump()
    }

    /// The app is back in front: try again whatever stopped while it wasn't.
    func resume() {
        suspended = false
        stopReason = nil
        pump()
    }

    // MARK: What's downloaded

    func state(of path: String) -> State {
        guard let item = items.first(where: { $0.path == path }) else { return .notDownloaded }
        if item.finished { return .downloaded }
        if let failure = item.failure { return .failed(failure) }
        if workers[path] != nil {
            let bytes = received[path] ?? 0
            return .downloading(item.size > 0 ? min(1, Double(bytes) / Double(item.size)) : nil)
        }
        return .queued
    }

    /// The downloaded copy of the video at `path`, to play instead of the share's.
    func localURL(for path: String) -> URL? {
        guard let item = items.first(where: { $0.path == path && $0.finished }) else { return nil }
        let url = Self.file(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The downloaded copy of one of its subtitle files.
    func localSubtitle(_ subtitle: SubtitleFile, of path: String) -> URL? {
        guard items.contains(where: { $0.path == path && $0.finished }) else { return nil }
        let url = Self.subtitleFile(subtitle, of: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var freeSpace: Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Changing what's downloaded

    /// Adds any of `videos` not already downloaded or on the way.
    func download(_ videos: [Video]) {
        let have = Set(items.map(\.path))
        let new = videos.filter { !have.contains($0.path) }.map {
            Item(path: $0.path, size: $0.fileSize, subtitles: $0.subtitles, addedAt: .now)
        }
        guard !new.isEmpty else { return }
        items += new
        pump()
        saveArtwork(for: videos.filter { v in new.contains { $0.path == v.path } })
    }

    /// The pictures these videos are shown with, saved now while the share
    /// is in reach. TMDB's are saved by every scan, but thumbnails on the
    /// share (the YouTube downloads') only once they've been on screen, and
    /// a video with neither shows a frame, which away from the share has to
    /// come from the download itself (see `FrameGrabber`).
    private func saveArtwork(for videos: [Video]) {
        guard let settings else { return }
        var refs: [String] = []
        for video in videos {
            let candidates = [video.posterRef ?? video.frameRef, video.backdropRef,
                              video.show?.posterRef, video.show?.backdropRef]
            for case let ref? in candidates where !refs.contains(ref) { refs.append(ref) }
        }
        // Frames last: they wait for the downloads to finish (see
        // `RootView`), and the rest needn't wait with them.
        refs = refs.filter { !$0.hasPrefix("frame:") } + refs.filter { $0.hasPrefix("frame:") }
        let config = settings.shareConfig, framesOnShare = settings.framesOnShare
        Task.detached(priority: .utility) {
            for ref in refs where !ArtworkStore.shared.isSaved(ref) {
                _ = await ArtworkStore.shared.image(for: ref, config: config, framesOnShare: framesOnShare)
            }
        }
    }

    func retry(_ path: String) {
        guard let i = items.firstIndex(where: { $0.path == path }) else { return }
        items[i].failure = nil
        resume()
    }

    /// Deletes the downloads, or stops them on the way.
    func remove(_ paths: [String]) {
        let gone = Set(paths)
        guard items.contains(where: { gone.contains($0.path) }) else { return }
        // One downloading stops before its next piece; it checks it's still
        // wanted before writing anything down.
        for (path, worker) in workers where gone.contains(path) { worker.cancel() }
        items.removeAll { gone.contains($0.path) }
        for path in gone { try? FileManager.default.removeItem(at: Self.folder(for: path)) }
    }

    func removeAll() {
        remove(items.map(\.path))
    }

    /// Drops unfinished downloads of videos a scan found gone from the
    /// share, which can't be finished now. Finished ones stay, and so do
    /// their videos in the library: see `LibrarySync.downloads`.
    func prune(context: ModelContext) {
        guard items.contains(where: { !$0.finished }),
              let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }
        let inLibrary = Set(videos.map(\.path))
        remove(items.filter { !$0.finished && !inLibrary.contains($0.path) }.map(\.path))
    }

    // MARK: Downloading

    private func pump() {
        guard !paused, !suspended, stopReason == nil, let settings, settings.isConfigured else {
            if workers.isEmpty { releaseBackgroundTime() }
            return
        }
        let config = settings.shareConfig
        let waiting = items.filter { !$0.finished && $0.failure == nil && workers[$0.path] == nil }
        for next in waiting.prefix(Self.maxConcurrent - workers.count) {
            holdBackgroundTime()
            let path = next.path
            workers[path] = Task {
                await run(next, config: config)
                workers[path] = nil
                received[path] = nil
                pump()
            }
        }
        if workers.isEmpty { releaseBackgroundTime() }
    }

    private func cancelAll() {
        for worker in workers.values { worker.cancel() }
    }

    private func run(_ item: Item, config: ShareConfig) async {
        received[item.path] = 0
        let path = item.path
        let folder = Self.folder(for: path)
        let final = Self.file(for: item)
        let partial = final.appendingPathExtension("part")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let have = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            if let free = Self.freeSpace, item.size - have > free - Self.spareSpace {
                throw DownloadError.noSpace(needed: item.size - have, free: free)
            }

            // Its own connection, so pieces of four downloads don't queue up
            // in front of the posters and progress on the shared one.
            let source = try config.makeSource()
            defer { Task { await source.disconnect() } }
            let fetch = {
                try await FileDownload.fetch(into: partial, read: { range in
                    try await source.read(path, range: range)
                }, progress: { [weak self] bytes in
                    await self?.update(received: bytes, of: path)
                })
            }
            var size = try await fetch()
            // A read that came back short partway looks just like the end of
            // the file, and a cut-off movie would only show itself mid-flight.
            // The share's listing says how big it really is.
            let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            if let expected = try? await source.list(parent).first(where: { !$0.isDirectory && $0.name == name })?.size {
                for _ in 0..<3 where size < expected { size = try await fetch() }
                if size < expected { throw DownloadError.incomplete(got: size, expected: expected) }
            }
            // Subtitles are small, and a missing one shouldn't spoil the
            // video, but losing the share partway should leave the download
            // to finish later rather than finish without them.
            for subtitle in item.subtitles {
                try Task.checkCancellation()
                let data: Data
                do {
                    data = try await source.read(subtitle.path)
                } catch let error where Self.isOutOfReach(error) {
                    throw error
                } catch {
                    continue
                }
                let url = Self.subtitleFile(subtitle, of: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            guard let i = items.firstIndex(where: { $0.path == path }) else { return }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            items[i].finished = true
            items[i].size = size
        } catch {
            // Paused, removed, or out of background time: what it has so far
            // is kept. A WebDAV request cut short says so as an error of its own.
            if error is CancellationError || Task.isCancelled { return }
            if Self.isOutOfReach(error) {
                // Not this video's fault, so it stays queued with the rest.
                stopReason = LibrarySync.describe(error)
                return
            }
            guard let i = items.firstIndex(where: { $0.path == path }) else { return }
            items[i].failure = LibrarySync.describe(error)
        }
    }

    private func update(received bytes: Int64, of path: String) {
        if workers[path] != nil { received[path] = bytes }
    }

    /// Losing the server, as opposed to a problem with the one file. SMB
    /// reports a connection lost partway through a read as a bare errno.
    private static func isOutOfReach(_ error: Error) -> Bool {
        if let share = error as? ShareError {
            switch share {
            case .server, .invalidHost, .share, .missingPath, .notWebDAV, .untrustedCertificate: return true
            case .folder, .noPartialReads: return false
            }
        }
        let ns = error as NSError
        guard ns.domain == NSPOSIXErrorDomain else { return error is URLError }
        return [ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, EBADF, ENETDOWN, ENETUNREACH,
                ENETRESET, EHOSTUNREACH, EHOSTDOWN].contains(Int32(ns.code))
    }

    /// Left free for the rest of the phone, so a download doesn't fill it.
    private static let spareSpace: Int64 = 1 << 30

    /// Lets a download carry on for the few minutes iOS allows once the app
    /// is put away. When they run out it stops, keeping what it has.
    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Download") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspended = true
                self.cancelAll()
                self.releaseBackgroundTime()
            }
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Files

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }

    private static func folder(for path: String) -> URL { DownloadFiles.folder(for: path) }

    private static func file(for item: Item) -> URL { DownloadFiles.file(for: item.path) }

    private static func subtitleFile(_ subtitle: SubtitleFile, of path: String) -> URL {
        folder(for: path).appendingPathComponent("Subtitles", isDirectory: true)
            .appendingPathComponent((subtitle.path as NSString).lastPathComponent)
    }
}

/// Where downloads are kept. Apart from `DownloadCenter` so code off the
/// main actor can find a downloaded file too.
enum DownloadFiles {
    static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Downloads", isDirectory: true)
    }()

    static func folder(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    /// Named as on the share, so VLC knows the format from the extension.
    /// Only there once the download has finished; until then it's a ".part".
    static func file(for path: String) -> URL {
        folder(for: path).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// The finished download of the video at `path`, if there is one.
    static func finished(_ path: String) -> URL? {
        let url = file(for: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum DownloadError: LocalizedError {
    case noSpace(needed: Int64, free: Int64)
    case incomplete(got: Int64, expected: Int64)

    var errorDescription: String? {
        switch self {
        case .noSpace(let needed, let free):
            return "Not enough space: it needs \(needed.formattedFileSize) and there's \(free.formattedFileSize) free."
        case .incomplete(let got, let expected):
            return "The share stopped sending at \(got.formattedFileSize) of \(expected.formattedFileSize)."
        }
    }
}
