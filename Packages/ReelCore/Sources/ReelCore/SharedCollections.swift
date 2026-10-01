import Foundation

/// A title put in or taken out of a collection by hand, and when. Merged
/// one title at a time, so picks made on two phones both stand.
public struct HandPick: Codable, Sendable, Hashable {
    /// In, out, or nil for back to whatever the filters say.
    public var included: Bool?
    public var at: Date

    public init(included: Bool?, at: Date) {
        self.included = included
        self.at = at
    }
}

/// Titles from any library gathered in a tab of their own: whatever its
/// filters match, plus titles added by hand, less any taken out by hand.
public struct CollectionConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rules: CollectionRules
    /// When the name or rules last changed. `longAgo` for the starter
    /// collection and ones from before syncing, so any real edit wins.
    public var updatedAt: Date
    /// By share path: `Video.path` for a movie, `Show.path` for a show.
    public var picks: [String: HandPick]

    public static let longAgo = Date(timeIntervalSince1970: 0)

    /// Now, to the second, which is all the share's ISO 8601 dates keep, so
    /// a change reads back from the share the same as it was made.
    public static var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    public init(id: UUID = UUID(), name: String, rules: CollectionRules, updatedAt: Date = Self.now, picks: [String: HandPick] = [:]) {
        self.id = id
        self.name = name
        self.rules = rules
        self.updatedAt = updatedAt
        self.picks = picks
    }

    public func contains(path: String, candidate: CollectionCandidate) -> Bool {
        picks[path]?.included ?? rules.matches(candidate)
    }

    /// Paths put in, or taken out, by hand.
    public func picked(_ included: Bool) -> [String] {
        picks.filter { $0.value.included == included }.map(\.key)
    }

    /// Puts a title in or takes it out by hand, or with nil hands it back to
    /// the filters. Remembered either way, so it stays put when the filters
    /// change, and so the change reaches the other phones.
    public mutating func set(_ path: String, included: Bool?, at date: Date = Self.now) {
        picks[path] = HandPick(included: included, at: date)
    }

    /// The newest of everything that's happened to it.
    public var lastChanged: Date {
        picks.values.map(\.at).reduce(updatedAt, max)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rules, updatedAt, picks, added, removed
    }

    /// Reads collections saved before syncing too, which kept hand picks as
    /// two sets of paths and had no dates.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rules = try c.decode(CollectionRules.self, forKey: .rules)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Self.longAgo
        if let picks = try c.decodeIfPresent([String: HandPick].self, forKey: .picks) {
            self.picks = picks
        } else {
            var picks: [String: HandPick] = [:]
            for path in try c.decodeIfPresent(Set<String>.self, forKey: .added) ?? [] {
                picks[path] = HandPick(included: true, at: Self.longAgo)
            }
            for path in try c.decodeIfPresent(Set<String>.self, forKey: .removed) ?? [] {
                picks[path] = HandPick(included: false, at: Self.longAgo)
            }
            self.picks = picks
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rules, forKey: .rules)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(picks, forKey: .picks)
    }
}

/// One install's copy of the collections it knows about.
public struct CollectionsFile: Codable, Sendable, Equatable {
    public var version = 1
    public var device: String
    public var collections: [CollectionConfig]
    /// Collections deleted, and when, so a copy on another phone doesn't
    /// bring them back.
    public var deleted: [UUID: Date]

    public init(device: String, collections: [CollectionConfig], deleted: [UUID: Date]) {
        self.device = device
        self.collections = collections
        self.deleted = deleted
    }
}

/// Collections kept on the share in `.reel/collections`, so every phone has
/// the same ones. As with `SharedProgress`, each install writes only its own
/// file and reading merges them all: the newest name and filters for each
/// collection, the newest hand pick for each title, and a deletion unless
/// the collection was changed after it.
public enum SharedCollections {
    public static let folder = ".reel/collections"

    public static func path(for device: String) -> String { "\(folder)/\(device).json" }

    public struct Merged: Sendable, Equatable {
        public var collections: [CollectionConfig] = []
        public var deleted: [UUID: Date] = [:]

        public init(collections: [CollectionConfig] = [], deleted: [UUID: Date] = [:]) {
            self.collections = collections
            self.deleted = deleted
        }
    }

    /// Collections come out in the order first seen, so put this install's
    /// own file first to keep its order.
    public static func merge(_ files: [CollectionsFile]) -> Merged {
        var order: [UUID] = []
        var byID: [UUID: CollectionConfig] = [:]
        var deleted: [UUID: Date] = [:]
        for file in files {
            for (id, date) in file.deleted where date > (deleted[id] ?? .distantPast) {
                deleted[id] = date
            }
            for collection in file.collections {
                guard var merged = byID[collection.id] else {
                    order.append(collection.id)
                    byID[collection.id] = collection
                    continue
                }
                if collection.updatedAt > merged.updatedAt {
                    merged.name = collection.name
                    merged.rules = collection.rules
                    merged.updatedAt = collection.updatedAt
                }
                for (path, pick) in collection.picks where pick.at > (merged.picks[path]?.at ?? .distantPast) {
                    merged.picks[path] = pick
                }
                byID[collection.id] = merged
            }
        }
        let collections = order.compactMap { byID[$0] }.filter { collection in
            guard let gone = deleted[collection.id] else { return true }
            return collection.lastChanged > gone
        }
        return Merged(collections: collections, deleted: deleted)
    }

    /// Every install's file. No folder yet means nobody has shared any. A
    /// file that won't decode, e.g. one mid-write, is skipped until next time.
    public static func load(from storage: any ProgressStorage) async throws -> [CollectionsFile] {
        let entries: [FileEntry]
        do {
            entries = try await storage.list(folder)
        } catch ShareError.folder {
            return []
        }
        var files: [CollectionsFile] = []
        // One at a time: the router's Samba copes badly with parallel reads.
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".json") {
            guard let data = try? await storage.read(entry.path, maxBytes: 5_000_000),
                  let file = try? decoder.decode(CollectionsFile.self, from: data) else { continue }
            files.append(file)
        }
        return files
    }

    public static func save(_ file: CollectionsFile, to storage: any ProgressStorage) async throws {
        try await storage.replace(path(for: file.device), with: encoder.encode(file))
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
