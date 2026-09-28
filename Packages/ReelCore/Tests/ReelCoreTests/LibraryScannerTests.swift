import XCTest
@testable import ReelCore

/// A share built from a list of file paths.
struct MemorySource: FileSource {
    var files: [String: Int64]

    init(_ paths: [String], size: Int64 = 1_000_000_000) {
        files = Dictionary(uniqueKeysWithValues: paths.map { ($0, size) })
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let prefix = path.isEmpty ? "" : path + "/"
        var seen: [String: FileEntry] = [:]
        for (file, size) in files where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count)
            let parts = rest.split(separator: "/", maxSplits: 1)
            let name = String(parts[0])
            let isDir = parts.count > 1
            seen[name] = FileEntry(name: name, path: prefix + name, isDirectory: isDir, size: isDir ? 0 : size)
        }
        return Array(seen.values)
    }
}

final class LibraryScannerTests: XCTestCase {

    func testMovieFolders() async throws {
        let source = MemorySource([
            "movies/Moana 2 (2024)/Moana 2 (2024) [1080p] [WEBRip] [5.1] [YTS.MX].mp4",
            "movies/Moana 2 (2024)/Moana 2 (2024) [1080p] [WEBRip] [5.1] [YTS.MX].da.srt",
            "movies/Bytte Bytte Baby (2023) [1080p] [WEBRip] [5.1] [YTS.MX]/Bytte.Bytte.Baby.2023.1080p.WEBRip.x264.AAC5.1-[YTS.MX].mp4",
            "movies/Bytte Bytte Baby (2023) [1080p] [WEBRip] [5.1] [YTS.MX]/Subs/2_English.srt",
            "movies/Bytte Bytte Baby (2023) [1080p] [WEBRip] [5.1] [YTS.MX]/Subs/.DS_Store",
            "movies/Bytte Bytte Baby (2023) [1080p] [WEBRip] [5.1] [YTS.MX]/Subs/info.nfo",
            "movies/Bytte Bytte Baby (2023) [1080p] [WEBRip] [5.1] [YTS.MX]/Subs/Old/3_English.srt",
            "movies/Movies/Toy Story 2/Toy Story 2.mkv",
            "movies/Movies/Jerry Maguire/Jerry.Maguire.1996.1080p.BluRay.mkv",
            "movies/.plexignore/whatever.mkv",
            "movies/Sicario (2015)/Sample/sample.mkv",
            "movies/Sicario (2015)/Sicario 2015 REPACK UHD BluRay 1080p DD Atmos 5 1 DoVi HDR10  x265-SM737.mkv",
        ])
        let result = try await LibraryScanner(source: source).scan(root: "movies", kind: .movies)
        XCTAssertEqual(result.movies.map(\.title), ["Bytte Bytte Baby", "Jerry Maguire", "Moana 2", "Sicario", "Toy Story 2"])
        let moana = try XCTUnwrap(result.movies.first { $0.title == "Moana 2" })
        XCTAssertEqual(moana.year, 2024)
        XCTAssertEqual(moana.video.subtitles.map(\.label), ["Danish"])
        let bytte = try XCTUnwrap(result.movies.first { $0.title == "Bytte Bytte Baby" })
        XCTAssertEqual(bytte.video.subtitles.map(\.label), ["English"])
        // Folder has no year; the filename does.
        XCTAssertEqual(result.movies.first { $0.title == "Jerry Maguire" }?.year, 1996)
    }

    func testShowsWithAndWithoutSeasonFolders() async throws {
        let source = MemorySource([
            "TV/Bob's Burgers/Bobs.Burgers.S10E13.Three.Girls.and.A.Little.Wharfy.1080p.DSNP.WEB-DL.DDP5.1.H.264-PHOENIX.mkv",
            "TV/Bob's Burgers/Season 4/Bobs.Burgers.S04E12.The.Frond.Files.1080p.WEB-DL.DD5.1.H.264-iT00NZ.mkv",
            "TV/The Office (US)/The.Office.US.S04E07E08.1080p.BluRay.x265-RARBG.mp4",
            "TV/The Office (US)/The.Office.US.S04E07E08.1080p.BluRay.x265-RARBG.da.srt",
            "TV/The Office (US)/The.Office.US.S04E09.1080p.BluRay.x265-RARBG.mp4",
            "TV/Pingu/aaf-pingu.special.pingu.at.the.wedding.party.dvdrip.xvid.avi",
            "TV/Pingu/Pingu.S01E01.avi",
            "TV/Common Side Effects/.keep",
        ])
        let result = try await LibraryScanner(source: source).scan(root: "TV", kind: .shows)
        XCTAssertEqual(result.shows.map(\.title), ["Bob's Burgers", "Pingu", "The Office"])

        let bobs = result.shows[0]
        XCTAssertEqual(bobs.episodes.map(\.season), [4, 10])

        let office = result.shows[2]
        XCTAssertEqual(office.country, "US")
        XCTAssertEqual(office.episodes[0].episodeEnd, 8)
        XCTAssertEqual(office.episodes[0].video.subtitles.map(\.label), ["Danish"])
        XCTAssertEqual(office.episodes[1].video.subtitles, [])

        let pingu = result.shows[1]
        XCTAssertEqual(pingu.episodes.map(\.episode), [nil, 1])
        XCTAssertEqual(pingu.episodes[0].season, 0)
    }

    func testPinchflatThumbnails() async throws {
        let dir = "childrens-shows/Curious George/Season 01"
        let stem = "Curious George - s01e01 - George Becomes a Traffic Guard 🐵 Curious George 🐵 Kids Cartoon 🐵 Kids Movies"
        let source = MemorySource([
            "\(dir)/\(stem).webm", "\(dir)/\(stem).nfo", "\(dir)/\(stem).jpg",
            "childrens-shows/Curious George/tvshow.nfo",
        ])
        let result = try await LibraryScanner(source: source).scan(root: "childrens-shows", kind: .shows)
        let ep = try XCTUnwrap(result.shows.first?.episodes.first)
        XCTAssertEqual(ep.video.thumbnailPath, "\(dir)/\(stem).jpg")
        XCTAssertEqual(ep.season, 1)
        XCTAssertEqual(ep.episode, 1)
    }

    func testPlaybackURLEscaping() throws {
        let config = SMBConfig(host: "192.168.8.1", share: "media", username: "eamon", password: "p@ss#1")
        let path = "TV/Bob's Burgers/Season 4/What [a] #name? 100%.mkv"
        let url = try XCTUnwrap(config.playbackURL(for: path))
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "192.168.8.1")
        XCTAssertEqual(c.user, "eamon")
        XCTAssertEqual(c.password, "p@ss#1")
        XCTAssertEqual(c.path, "/media/" + path)
        XCTAssertNil(c.query)
        XCTAssertNil(c.fragment)
    }
}
