import XCTest
@testable import ReelCore

final class ConnectionTests: XCTestCase {

    func testParseAddress() {
        XCTAssertEqual(parse("192.168.8.1"), ["192.168.8.1", nil, nil])
        XCTAssertEqual(parse(" smb://nomad.local/media "), ["nomad.local", "media", nil])
        XCTAssertEqual(parse("SMB://eamon@192.168.8.1/backup/library/movies/"), ["192.168.8.1", "backup", "library/movies"])
        XCTAssertEqual(parse("\\\\nomad\\media\\TV"), ["nomad", "media", "TV"])
        XCTAssertEqual(parse("nomad.local:445/share"), ["nomad.local:445", "share", nil])
        XCTAssertEqual(parse("smb://host/My%20Share"), ["host", "My Share", nil])
        XCTAssertEqual(parse(""), ["", nil, nil])
    }

    private func parse(_ s: String) -> [String?] {
        let p = SMBConfig.parse(address: s)
        return [p.host, p.share, p.path]
    }

    func testGuestCredential() {
        XCTAssertEqual(SMBConfig(host: "h", share: "s", username: "", password: "").credential.user, "guest")
        XCTAssertEqual(SMBConfig(host: "h", share: "s", username: "eamon", password: "x").credential.user, "eamon")
    }

    func testFriendlyErrors() {
        let refused = SMBError.server(host: "nomad", code: ECONNREFUSED, detail: "STATUS_LOGON_FAILURE")
        XCTAssertTrue(refused.errorDescription!.contains("refused the login"))
        let unknown = SMBError.server(host: "nomad", code: EIO, detail: "Invalid address:nomad  Can not resolve into IPv4/v6.")
        XCTAssertTrue(unknown.errorDescription!.contains("Couldn't find a server"))
        XCTAssertTrue(SMBError.share(name: "media", code: ENOENT, detail: "").errorDescription!.contains("no share called"))
    }

    func testLocatorFindsNestedLibraries() async throws {
        let source = MemorySource([
            "Bucket_A/library/movies/Moana (2016)/Moana.mp4",
            "Bucket_A/library/TV/Bluey/Bluey.S01E01.mkv",
            "Bucket_A/library/childrens-shows/Bluey/Season 01/x.webm",
            "Bucket_A/subvol-102-disk-0/home/docker/movies/decoy.mkv",
            "Bucket_A/photos/2024/img.jpg",
        ])
        let found = try await LibraryLocator(source: source).find(["movies", "TV", "childrens-shows", "missing"])
        XCTAssertEqual(found["movies"], "Bucket_A/library/movies")
        XCTAssertEqual(found["TV"], "Bucket_A/library/TV")
        XCTAssertEqual(found["childrens-shows"], "Bucket_A/library/childrens-shows")
        XCTAssertNil(found["missing"])
    }

    func testLocatorToleratesRepeatedNames() async throws {
        // Two libraries whose folders share a name used to crash the lookup.
        let source = MemorySource(["library/movies/a.mkv"])
        let found = try await LibraryLocator(source: source).find(["movies", "Movies", "movies"])
        XCTAssertEqual(found["movies"], "library/movies")
    }

    func testConnectionErrorsAreRecognised() {
        XCTAssertTrue(SMBFileSource.isConnectionError(ENOTCONN))
        XCTAssertTrue(SMBFileSource.isConnectionError(ETIMEDOUT))
        XCTAssertFalse(SMBFileSource.isConnectionError(ENOENT))
        XCTAssertFalse(SMBFileSource.isConnectionError(EACCES))
    }

    func testLocatorPrefersShallowest() async throws {
        let source = MemorySource(["movies/a.mkv", "old/backup/movies/b.mkv"])
        let found = try await LibraryLocator(source: source).find(["movies"])
        XCTAssertEqual(found["movies"], "movies")
    }
}
