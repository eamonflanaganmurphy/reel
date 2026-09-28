import XCTest
@testable import ReelCore

/// Progress files in memory. A missing folder fails the way the share does.
actor MemoryProgressStorage: ProgressStorage {
    var files: [String: Data] = [:]

    func list(_ path: String) async throws -> [FileEntry] {
        let prefix = path + "/"
        let names = files.keys.filter { $0.hasPrefix(prefix) }
        if names.isEmpty { throw SMBError.folder(path: path, code: ENOENT, detail: "No such file or directory") }
        return names.map { FileEntry(name: String($0.dropFirst(prefix.count)), path: $0, isDirectory: false) }
    }

    func read(_ path: String, maxBytes: UInt64) async throws -> Data {
        guard let data = files[path] else { throw POSIXError(.ENOENT) }
        return data
    }

    func replace(_ path: String, with data: Data) async throws {
        files[path] = data
    }

    func put(_ path: String, _ data: Data) { files[path] = data }
}

final class SharedProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNewestEntryWins() {
        let phone = ProgressFile(device: "phone", entries: [
            "TV/Bluey/S01E01.mkv": WatchProgress(position: 300, duration: 420, watched: false, updatedAt: t0),
            "movies/Moana.mkv": WatchProgress(position: 0, duration: 6000, watched: true, updatedAt: t0.addingTimeInterval(50)),
        ])
        let ipad = ProgressFile(device: "ipad", entries: [
            "TV/Bluey/S01E01.mkv": WatchProgress(position: 400, duration: 420, watched: false, updatedAt: t0.addingTimeInterval(100)),
            "movies/Moana.mkv": WatchProgress(position: 1200, duration: 6000, watched: false, updatedAt: t0),
        ])
        let merged = SharedProgress.merge([phone, ipad])
        XCTAssertEqual(merged["TV/Bluey/S01E01.mkv"]?.position, 400)
        XCTAssertEqual(merged["movies/Moana.mkv"]?.watched, true)
        XCTAssertEqual(SharedProgress.merge([ipad, phone]), merged, "order of the files mustn't matter")
    }

    func testNoFolderYetIsEmpty() async throws {
        let loaded = try await SharedProgress.load(from: MemoryProgressStorage())
        XCTAssertTrue(loaded.isEmpty)
    }

    func testRoundTripAcrossDevices() async throws {
        let storage = MemoryProgressStorage()
        let entry = WatchProgress(position: 1234.5, duration: 2700, watched: false, updatedAt: t0)
        try await SharedProgress.save(["movies/Sicario.mkv": entry], device: "A", to: storage)
        try await SharedProgress.save(["TV/Bluey/S01E02.mkv": entry], device: "B", to: storage)

        let loaded = try await SharedProgress.load(from: storage)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["movies/Sicario.mkv"], entry)
        let files = await storage.files.keys.sorted()
        XCTAssertEqual(files, [".reel/progress/A.json", ".reel/progress/B.json"])
    }

    func testUnreadableFileIsSkipped() async throws {
        let storage = MemoryProgressStorage()
        let entry = WatchProgress(position: 60, duration: 600, watched: false, updatedAt: t0)
        try await SharedProgress.save(["a.mkv": entry], device: "A", to: storage)
        await storage.put(".reel/progress/B.json", Data("{\"dev".utf8))
        await storage.put(".reel/progress/B.json.tmp", Data("junk".utf8))

        let loaded = try await SharedProgress.load(from: storage)
        XCTAssertEqual(loaded, ["a.mkv": entry])
    }
}
