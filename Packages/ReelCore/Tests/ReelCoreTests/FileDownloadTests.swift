import XCTest
@testable import ReelCore

final class FileDownloadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Reads a file in memory the way the share does: short at the end,
    /// nothing past it.
    private static func reader(_ file: Data, reads: Counter? = nil) -> @Sendable (Range<UInt64>) async throws -> Data {
        { range in
            await reads?.add(1)
            let start = min(Int(range.lowerBound), file.count)
            let end = min(Int(range.upperBound), file.count)
            return file.subdata(in: start..<end)
        }
    }

    private static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    func testWholeFile() async throws {
        let file = Self.bytes(10_000)
        let partial = folder.appendingPathComponent("a.mkv.part")
        let seen = Counter()
        let size = try await FileDownload.fetch(into: partial, pieceSize: 4096, read: Self.reader(file)) { bytes in
            await seen.set(Int(bytes))
        }
        XCTAssertEqual(size, 10_000)
        XCTAssertEqual(try Data(contentsOf: partial), file)
        let last = await seen.value
        XCTAssertEqual(last, 10_000)
    }

    /// A size that's a whole number of pieces ends with an empty read.
    func testExactMultipleOfPieces() async throws {
        let file = Self.bytes(8192)
        let partial = folder.appendingPathComponent("b.mkv.part")
        let reads = Counter()
        let size = try await FileDownload.fetch(into: partial, pieceSize: 4096, read: Self.reader(file, reads: reads))
        XCTAssertEqual(size, 8192)
        XCTAssertEqual(try Data(contentsOf: partial), file)
        let count = await reads.value
        XCTAssertEqual(count, 3)
    }

    func testCarriesOnFromPartial() async throws {
        let file = Self.bytes(10_000)
        let partial = folder.appendingPathComponent("c.mkv.part")
        try file.prefix(6000).write(to: partial)
        let firstRead = Counter()
        let size = try await FileDownload.fetch(into: partial, pieceSize: 4096, read: { range in
            if await firstRead.value == 0 { await firstRead.set(Int(range.lowerBound)) }
            return try await Self.reader(file)(range)
        })
        XCTAssertEqual(size, 10_000)
        XCTAssertEqual(try Data(contentsOf: partial), file)
        let start = await firstRead.value
        XCTAssertEqual(start, 6000)
    }

    func testEmptyFile() async throws {
        let partial = folder.appendingPathComponent("d.mkv.part")
        let size = try await FileDownload.fetch(into: partial, read: Self.reader(Data()))
        XCTAssertEqual(size, 0)
        XCTAssertEqual(try Data(contentsOf: partial), Data())
    }

    /// A failed read keeps what came before it, for the next try.
    func testFailureKeepsWhatItHas() async throws {
        let file = Self.bytes(10_000)
        let partial = folder.appendingPathComponent("e.mkv.part")
        do {
            try await FileDownload.fetch(into: partial, pieceSize: 4096, read: { range in
                if range.lowerBound >= 4096 { throw Dropped() }
                return try await Self.reader(file)(range)
            })
            XCTFail("Should have thrown")
        } catch is Dropped {}
        XCTAssertEqual(try Data(contentsOf: partial), file.prefix(4096))

        try await FileDownload.fetch(into: partial, pieceSize: 4096, read: Self.reader(file))
        XCTAssertEqual(try Data(contentsOf: partial), file)
    }

    func testWebDAVPieces() throws {
        let body = Data(repeating: 7, count: 100)
        // The server honoured the range.
        XCTAssertEqual(try WebDAVFileSource.piece(of: body, status: 206, range: 50..<150, host: "h"), body)
        // It ignored it, but the read was from the start anyway.
        XCTAssertEqual(try WebDAVFileSource.piece(of: body, status: 200, range: 0..<10, host: "h")?.count, 10)
        // It ignored it partway through a file.
        XCTAssertThrowsError(try WebDAVFileSource.piece(of: body, status: 200, range: 10..<20, host: "h"))
        // Past the end.
        XCTAssertEqual(try WebDAVFileSource.piece(of: Data(), status: 416, range: 100..<200, host: "h"), Data())
        XCTAssertNil(try WebDAVFileSource.piece(of: Data(), status: 404, range: 0..<10, host: "h"))
    }
}

private struct Dropped: Error {}

private actor Counter {
    private(set) var value = 0
    func add(_ n: Int) { value += n }
    func set(_ n: Int) { value = n }
}
