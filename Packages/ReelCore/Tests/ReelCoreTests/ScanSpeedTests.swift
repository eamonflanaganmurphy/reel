import XCTest
@testable import ReelCore

/// A share whose folders have modified dates, counting what's listed.
final class DatedSource: FileSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: MemorySource
    private var dates: [String: Date]
    private var calls: [String] = []

    init(_ paths: [String], dates: [String: Date]) {
        tree = MemorySource(paths)
        self.dates = dates
    }

    var listed: [String] { lock.withLock { calls } }

    func reset() { lock.withLock { calls = [] } }

    /// Adds a file the way a copy does, which changes its folder's date.
    func add(_ path: String, folderDate: Date?) {
        lock.withLock {
            tree.files[path] = 1_000_000_000
            if let folderDate { dates[(path as NSString).deletingLastPathComponent] = folderDate }
        }
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let (tree, dates): (MemorySource, [String: Date]) = lock.withLock {
            calls.append(path)
            return (self.tree, self.dates)
        }
        return try await tree.list(path).map { entry in
            var entry = entry
            if entry.isDirectory { entry.modified = dates[entry.path] }
            return entry
        }
    }
}

final class ScanSpeedTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_700_086_400)

    private func showsSource() -> DatedSource {
        DatedSource([
            "TV/Bluey (2018)/Season 1/Bluey - S01E01 - Magic Xylophone.mkv",
            "TV/Bluey (2018)/Season 1/Bluey - S01E02 - Hospital.mkv",
            "TV/Bluey (2018)/Season 2/Bluey - S02E01 - Dance Mode.mkv",
            "TV/Bluey (2018)/poster.jpg",
        ], dates: [
            "TV/Bluey (2018)": day1,
            "TV/Bluey (2018)/Season 1": day1,
            "TV/Bluey (2018)/Season 2": day1,
        ])
    }

    func testUnchangedFoldersAreNotListedAgain() async throws {
        let source = showsSource()
        let first = ListingCache(base: source, previous: [:])
        let before = try await LibraryScanner(source: first).scan(root: "TV", kind: .shows)
        XCTAssertEqual(first.reused, 0)

        source.reset()
        let second = ListingCache(base: source, previous: first.folders)
        let after = try await LibraryScanner(source: second).scan(root: "TV", kind: .shows)
        XCTAssertEqual(after.shows, before.shows)
        // The library and the show folder hold folders, so they're listed;
        // the seasons aren't.
        XCTAssertEqual(Set(source.listed), ["TV", "TV/Bluey (2018)"])
        XCTAssertEqual(second.reused, 2)
        // And the next scan can reuse them again.
        XCTAssertEqual(Set(second.folders.keys), Set(first.folders.keys))
    }

    func testAChangedFolderIsListedAgain() async throws {
        let source = showsSource()
        let first = ListingCache(base: source, previous: [:])
        _ = try await LibraryScanner(source: first).scan(root: "TV", kind: .shows)

        source.add("TV/Bluey (2018)/Season 2/Bluey - S02E02 - Hammerbarn.mkv", folderDate: day2)
        source.reset()
        let second = ListingCache(base: source, previous: first.folders)
        let result = try await LibraryScanner(source: second).scan(root: "TV", kind: .shows)
        XCTAssertEqual(result.shows.first?.episodes.count, 4)
        XCTAssertTrue(source.listed.contains("TV/Bluey (2018)/Season 2"))
        XCTAssertFalse(source.listed.contains("TV/Bluey (2018)/Season 1"))
    }

    func testFoldersWithNoDateAreAlwaysListed() async throws {
        let source = DatedSource(["movies/Moana (2016)/Moana (2016).mkv"], dates: [:])
        let first = ListingCache(base: source, previous: [:])
        _ = try await LibraryScanner(source: first).scan(root: "movies", kind: .movies)
        source.reset()
        let second = ListingCache(base: source, previous: first.folders)
        let result = try await LibraryScanner(source: second).scan(root: "movies", kind: .movies)
        XCTAssertEqual(result.movies.count, 1)
        XCTAssertEqual(second.reused, 0)
        XCTAssertEqual(Set(source.listed), ["movies", "movies/Moana (2016)"])
    }

    func testScanningSeveralFoldersAtOnceFindsTheSame() async throws {
        var paths: [String] = []
        for i in 1...30 {
            paths.append("movies/Film \(i) (20\(10 + i % 10))/Film \(i).mkv")
            paths.append("movies/Film \(i) (20\(10 + i % 10))/Subs/English.srt")
            paths.append("TV/Show \(i)/Season 1/Show \(i) - S01E01.mkv")
            paths.append("TV/Show \(i)/Season 2/Show \(i) - S02E01.mkv")
        }
        let source = MemorySource(paths)
        let pool = SourcePool([source, source, source])
        let one = try await LibraryScanner(source: source).scan(root: "movies", kind: .movies)
        let many = try await LibraryScanner(source: pool, concurrency: 4).scan(root: "movies", kind: .movies)
        XCTAssertEqual(Set(many.movies), Set(one.movies))
        XCTAssertEqual(many.movies.count, 30)

        let shows = try await LibraryScanner(source: pool, concurrency: 4).scan(root: "TV", kind: .shows)
        XCTAssertEqual(shows.shows.count, 30)
        XCTAssertEqual(shows.shows.map(\.title), shows.shows.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testAFailedListingStillFreesItsConnection() async throws {
        struct Failing: FileSource {
            func list(_ path: String) async throws -> [FileEntry] {
                throw ShareError.server(host: "nomad", code: ETIMEDOUT, detail: "timed out")
            }
        }
        let pool = SourcePool([Failing()])
        for _ in 0..<3 {
            do {
                _ = try await pool.list("movies")
                XCTFail("Expected an error")
            } catch {}
        }
    }
}
