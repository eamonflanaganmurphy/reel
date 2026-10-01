import XCTest
@testable import ReelCore

final class SharedFramesTests: XCTestCase {
    /// The names are how phones find each other's frames, so they mustn't
    /// change between builds or differ between devices.
    func testNamesAreStable() {
        XCTAssertEqual(SharedFrames.name(for: ""), "cbf29ce484222325.jpg")
        XCTAssertEqual(SharedFrames.name(for: "a"), "af63dc4c8601ec8c.jpg", "FNV-1a's published value")
        XCTAssertEqual(SharedFrames.path(for: "childrens-shows/Bluey/Bluey - S01E01.mkv"),
                       ".reel/frames/1541c843ad7a16e7.jpg")
        XCTAssertNotEqual(SharedFrames.name(for: "TV/Bluey/S01E01.mkv"), SharedFrames.name(for: "TV/Bluey/S01E02.mkv"))
    }

    func testNoFolderYetIsEmpty() async throws {
        let names = try await SharedFrames.list(in: MemoryProgressStorage())
        XCTAssertTrue(names.isEmpty)
    }

    func testListsSavedFramesOnly() async throws {
        let storage = MemoryProgressStorage()
        let video = "childrens-shows/Bluey/Bluey - S01E01.mkv"
        try await storage.replace(SharedFrames.path(for: video), with: Data([0xFF, 0xD8]))
        await storage.put(SharedFrames.path(for: "other.mkv") + ".1A2B3C4D.tmp", Data())

        let names = try await SharedFrames.list(in: storage)
        XCTAssertEqual(names, [SharedFrames.name(for: video)], "a half-written frame isn't one")
    }
}
