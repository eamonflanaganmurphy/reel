import Foundation

/// Finds library folders by name wherever they sit in a share. The Nomad
/// router holds a mirror of the whole pool, so "movies" can be a few levels
/// down rather than at the top.
public struct LibraryLocator: Sendable {
    public var source: any FileSource
    public var maxDepth = 5
    /// Upper bound on directory listings, so a share holding a full disk
    /// backup can't turn this into a crawl of every folder on it.
    public var maxListings = 400

    public init(source: any FileSource) {
        self.source = source
    }

    /// Breadth-first, so the shallowest match wins. Returns share-relative
    /// paths keyed by the name asked for; names not found are absent.
    public func find(_ names: [String]) async throws -> [String: String] {
        // Two libraries can want the same name ("disk1/movies", "disk2/movies").
        var wanted = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var found: [String: String] = [:]
        var level = [""]
        var listings = 0

        for _ in 0..<maxDepth {
            var next: [String] = []
            for dir in level {
                guard listings < maxListings, !wanted.isEmpty else { return found }
                listings += 1
                // Unreadable folders are common in a backup; skip them.
                guard let entries = try? await source.list(dir) else {
                    if dir.isEmpty { _ = try await source.list(dir) } // surface connection errors
                    continue
                }
                for e in entries where e.isDirectory && !LibraryScanner.isIgnored(e.name) {
                    if let original = wanted.removeValue(forKey: e.name.lowercased()) {
                        found[original] = e.path
                    } else if !Self.skip(e.name) {
                        next.append(e.path)
                    }
                }
            }
            if wanted.isEmpty || next.isEmpty { break }
            level = next
        }
        return found
    }

    /// Folders that never hold media but can hold thousands of subfolders.
    static func skip(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["proc", "sys", "dev", "etc", "usr", "var", "lib", "bin", "sbin", "opt", "tmp", "run",
                "boot", "snap", "node_modules", "config", "appdata", "cache", "logs", "incomplete"].contains(lower)
            || lower.hasPrefix("subvol-")
    }
}
