import Foundation

/// Where someone got to in one file.
public struct WatchProgress: Codable, Sendable, Equatable {
    public var position: Double
    public var duration: Double
    public var watched: Bool
    public var updatedAt: Date

    public init(position: Double, duration: Double, watched: Bool, updatedAt: Date) {
        self.position = position
        self.duration = duration
        self.watched = watched
        self.updatedAt = updatedAt
    }
}

/// One install's copy of the progress it knows about, keyed by share path.
public struct ProgressFile: Codable, Sendable, Equatable {
    public var version = 1
    public var device: String
    public var entries: [String: WatchProgress]

    public init(device: String, entries: [String: WatchProgress]) {
        self.device = device
        self.entries = entries
    }
}

/// Somewhere progress files (and shared frames) can be kept: the share in
/// the app, memory in tests.
public protocol ProgressStorage: Sendable {
    func list(_ path: String) async throws -> [FileEntry]
    func read(_ path: String, maxBytes: UInt64) async throws -> Data
    func replace(_ path: String, with data: Data) async throws
}

/// Watch progress kept on the share itself, in `.reel/progress`, so every
/// copy of the app (another phone, a reinstall, a newer build) agrees on
/// where you got to. There's no server to arbitrate, so each install writes
/// only its own file, named by an ID it keeps, and two phones never write
/// the same file. Reading merges them all, and the newest entry for a path wins.
public enum SharedProgress {
    public static let folder = ".reel/progress"

    public static func path(for device: String) -> String { "\(folder)/\(device).json" }

    /// Newest entry per path across all the files.
    public static func merge(_ files: [ProgressFile]) -> [String: WatchProgress] {
        var merged: [String: WatchProgress] = [:]
        for file in files {
            for (path, entry) in file.entries where entry.updatedAt > (merged[path]?.updatedAt ?? .distantPast) {
                merged[path] = entry
            }
        }
        return merged
    }

    /// Everything every install has recorded. No folder yet means nobody has
    /// watched anything. A file that won't decode, e.g. one mid-write, is
    /// skipped until next time.
    public static func load(from storage: any ProgressStorage) async throws -> [String: WatchProgress] {
        let entries: [FileEntry]
        do {
            entries = try await storage.list(folder)
        } catch ShareError.folder {
            return [:]
        }
        var files: [ProgressFile] = []
        // One at a time: the router's Samba copes badly with parallel reads.
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".json") {
            guard let data = try? await storage.read(entry.path, maxBytes: 20_000_000),
                  let file = try? decoder.decode(ProgressFile.self, from: data) else { continue }
            files.append(file)
        }
        return merge(files)
    }

    public static func save(_ entries: [String: WatchProgress], device: String, to storage: any ProgressStorage) async throws {
        let data = try encoder.encode(ProgressFile(device: device, entries: entries))
        try await storage.replace(path(for: device), with: data)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
