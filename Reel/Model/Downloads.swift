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
/// One downloads at a time, a piece at a time (see `FileDownload`), and
/// only while nothing else is reading from the router: a scan or a video
/// streaming from it pauses the download, which carries on from where it
/// got to once they're done, as it does after the app has been put away.
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
    /// Bytes so far of the one downloading.
    private(set) var received: Int64 = 0
    /// The path of the one downloading.
    private(set) var current: String?
    /// Why the queue has stopped, e.g. the share is out of reach. Cleared
    /// when the app comes back to the front, or by Try Again.
    private(set) var stopReason: String?

    /// Set while a scan or a video streaming from the share is using the
    /// router. A download under way stops and carries on after.
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused { worker?.cancel() } else { pump() }
        }
    }

    var isDownloading: Bool { current != nil }

    /// Bytes on this device in finished downloads.
    var bytesOnDevice: Int64 { items.filter(\.finished).reduce(0) { $0 + $1.size } }

    private weak var settings: AppSettings?
    private var worker: Task<Void, Never>?
    /// The app was put away and its time to finish in the background ran
    /// out. The queue waits for it to come back.
    private var suspended = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Downloads", isDirectory: true)
    }()

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
        if current == path { return .downloading(item.size > 0 ? min(1, Double(received) / Double(item.size)) : nil) }
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
        // The one downloading stops before its next piece; it checks it's
        // still wanted before writing anything down.
        if let current, gone.contains(current) { worker?.cancel() }
        items.removeAll { gone.contains($0.path) }
        for path in gone { try? FileManager.default.removeItem(at: Self.folder(for: path)) }
    }

    func removeAll() {
        remove(items.map(\.path))
    }

    /// Drops downloads of videos a scan found gone from the share, which
    /// there's no longer a way to play.
    func prune(context: ModelContext) {
        guard !items.isEmpty, let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }
        let onShare = Set(videos.map(\.path))
        remove(items.map(\.path).filter { !onShare.contains($0) })
    }

    // MARK: Downloading

    private func pump() {
        guard worker == nil, !paused, !suspended, stopReason == nil,
              let settings, settings.isConfigured,
              let next = items.first(where: { !$0.finished && $0.failure == nil })
        else {
            if worker == nil { releaseBackgroundTime() }
            return
        }
        holdBackgroundTime()
        let config = settings.shareConfig
        worker = Task {
            await run(next, config: config)
            worker = nil
            pump()
        }
    }

    private func run(_ item: Item, config: ShareConfig) async {
        current = item.path
        received = 0
        defer { current = nil }
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

            let source = try ServerConnection.shared.source(for: config)
            let size = try await FileDownload.fetch(into: partial, read: { range in
                try await source.read(path, range: range)
            }, progress: { [weak self] bytes in
                await self?.update(received: bytes, of: path)
            })
            // Subtitles are small, and a missing one shouldn't spoil the video.
            for subtitle in item.subtitles {
                try Task.checkCancellation()
                if let data = try? await source.read(subtitle.path) {
                    let url = Self.subtitleFile(subtitle, of: path)
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: url, options: .atomic)
                }
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
        if current == path { received = bytes }
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
                self.worker?.cancel()
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

    private static func folder(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    /// Named as on the share, so VLC knows the format from the extension.
    private static func file(for item: Item) -> URL {
        folder(for: item.path).appendingPathComponent(item.fileName)
    }

    private static func subtitleFile(_ subtitle: SubtitleFile, of path: String) -> URL {
        folder(for: path).appendingPathComponent("Subtitles", isDirectory: true)
            .appendingPathComponent((subtitle.path as NSString).lastPathComponent)
    }
}

enum DownloadError: LocalizedError {
    case noSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .noSpace(let needed, let free):
            return "Not enough space: it needs \(needed.formattedFileSize) and there's \(free.formattedFileSize) free."
        }
    }
}
