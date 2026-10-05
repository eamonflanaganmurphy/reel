import Foundation

/// Remembers each folder's listing from the last scan, so a folder that
/// hasn't changed isn't listed again. A folder's modified date changes when
/// a file is added to it, removed or renamed (which is how the mirror and
/// most copies put a finished file in place), and its parent's listing gives
/// that date for free.
///
/// It only covers that one level, though: a folder's date doesn't change
/// when something deeper down does. So a listing is only reused for a folder
/// with no folders of its own, which is most of them: season folders and
/// most movie folders. Anything above them is listed every time, and so
/// looks fresh at the dates of the folders below.
///
/// Changing a file in place, keeping its name, doesn't change its folder's
/// date, so the size from the last scan can be out of date until a full scan.
public final class ListingCache: FileSource, @unchecked Sendable {
    /// One folder's listing, and its modified date when it was listed.
    public struct Folder: Codable, Sendable, Equatable {
        public var modified: Date
        public var entries: [FileEntry]

        public init(modified: Date, entries: [FileEntry]) {
            self.modified = modified
            self.entries = entries
        }
    }

    private let base: any FileSource
    private let previous: [String: Folder]
    private let lock = NSLock()
    // Guarded by lock.
    private var current: [String: Folder] = [:]
    private var dates: [String: Date] = [:]
    private var reusedCount = 0

    /// `previous` is what the last scan's `folders` were.
    public init(base: any FileSource, previous: [String: Folder]) {
        self.base = base
        self.previous = previous
    }

    /// The folders this scan listed or reused, to pass to the next one.
    public var folders: [String: Folder] { lock.withLock { current } }

    /// How many folders weren't listed again.
    public var reused: Int { lock.withLock { reusedCount } }

    public func list(_ path: String) async throws -> [FileEntry] {
        let key = Self.key(path)
        if let entries = lock.withLock({ reuse(key) }) { return entries }
        let entries = try await base.list(path)
        lock.withLock {
            for entry in entries where entry.isDirectory {
                if let modified = entry.modified { dates[Self.key(entry.path)] = modified }
            }
            if let modified = dates[key] { current[key] = Folder(modified: modified, entries: entries) }
        }
        return entries
    }

    /// The last scan's listing of the folder at `key`, if it's still good.
    private func reuse(_ key: String) -> [FileEntry]? {
        guard let modified = dates[key], let old = previous[key],
              abs(old.modified.timeIntervalSince(modified)) < 0.001,
              // Folders the scanner skips (a NAS's thumbnail folders) don't count.
              !old.entries.contains(where: { $0.isDirectory && !LibraryScanner.isIgnored($0.name) })
        else { return nil }
        current[key] = old
        reusedCount += 1
        return old.entries
    }

    private static func key(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}

/// Lists folders over several connections at once. One SMB connection
/// handles one request at a time, waiting on the router for each, so a scan
/// of a few thousand folders is mostly waiting; a few connections take turns
/// with that. Each request goes to whichever connection is free.
///
/// The first connection is the one the rest of the app uses. If one of the
/// others fails (the router won't open another session, or it times out
/// under the extra load), it's dropped and the folder is listed again over
/// the ones left, down to just the first; `retired` says how many went. Only
/// a failure on the first, or one that's about the folder itself, reaches
/// the caller, as it would with no pool.
public final class SourcePool: FileSource, Sendable {
    private let sources: [any FileSource]
    private let free: FreeList

    /// `sources` should be separate connections to the same share, the
    /// app's own first. A WebDAV one can appear more than once: HTTP has no
    /// session to wait on.
    public init(_ sources: [any FileSource]) {
        precondition(!sources.isEmpty)
        self.sources = sources
        free = FreeList(count: sources.count)
    }

    /// How many connections have been dropped for failing.
    public var retired: Int {
        get async { await free.retired }
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        while true {
            let i = await free.take()
            // The scan has already failed elsewhere: a folder waiting for a
            // connection needn't make it wait any longer.
            if Task.isCancelled {
                await free.give(i)
                throw CancellationError()
            }
            do {
                let entries = try await sources[i].list(path)
                await free.give(i)
                return entries
            } catch {
                if i == 0 || Self.isAboutTheFolder(error) {
                    await free.give(i)
                    throw error
                }
                await free.retire(i)
            }
        }
    }

    /// A folder that's gone or can't be read fails the same way on any
    /// connection.
    private static func isAboutTheFolder(_ error: any Error) -> Bool {
        guard let share = error as? ShareError else { return false }
        switch share {
        case .folder, .missingPath: return true
        default: return false
        }
    }

    private actor FreeList {
        private var free: [Int]
        private var waiting: [CheckedContinuation<Int, Never>] = []
        private(set) var retired = 0

        init(count: Int) {
            // Popped from the end, so the first connection goes first.
            free = Array((0..<count).reversed())
        }

        func take() async -> Int {
            if let i = free.popLast() { return i }
            return await withCheckedContinuation { waiting.append($0) }
        }

        func give(_ i: Int) {
            if waiting.isEmpty {
                free.append(i)
            } else {
                waiting.removeFirst().resume(returning: i)
            }
        }

        /// Never handed out again. The first connection never is retired,
        /// so there's always one to wait for.
        func retire(_ i: Int) {
            retired += 1
        }
    }
}
