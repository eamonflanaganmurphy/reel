import XCTest
@testable import ReelCore

final class WebDAVTests: XCTestCase {

    func testParseAddress() {
        XCTAssertEqual(parse("http://192.168.8.1/webdav"), ["192.168.8.1", "webdav", "false"])
        XCTAssertEqual(parse(" https://nas.local:5006/video/ "), ["nas.local:5006", "video", "true"])
        XCTAssertEqual(parse("davs://eamon@cloud.example.com/remote.php/dav/files/eamon/"),
                       ["cloud.example.com", "remote.php/dav/files/eamon", "true"])
        XCTAssertEqual(parse("WEBDAV://nomad/My%20Films"), ["nomad", "My Films", "false"])
        XCTAssertEqual(parse("192.168.8.1:8080"), ["192.168.8.1:8080", "", "nil"])
        XCTAssertEqual(parse("https://host/dav?x=1"), ["host", "dav", "true"])
        XCTAssertEqual(parse(""), ["", "", "nil"])
    }

    private func parse(_ s: String) -> [String] {
        let p = ShareConfig.parse(webDAVAddress: s)
        return [p.host, p.path, p.secure.map { "\($0)" } ?? "nil"]
    }

    func testPlainHTTPGuess() {
        XCTAssertTrue(ShareConfig.prefersPlainHTTP(host: "192.168.8.1"))
        XCTAssertTrue(ShareConfig.prefersPlainHTTP(host: "192.168.8.1:8080"))
        XCTAssertTrue(ShareConfig.prefersPlainHTTP(host: "nomad"))
        XCTAssertTrue(ShareConfig.prefersPlainHTTP(host: "nomad.local"))
        XCTAssertTrue(ShareConfig.prefersPlainHTTP(host: "[fe80::1]:80"))
        XCTAssertFalse(ShareConfig.prefersPlainHTTP(host: "cloud.example.com"))
        XCTAssertFalse(ShareConfig.prefersPlainHTTP(host: "nomad.tail1234.ts.net"))
    }

    func testURLs() throws {
        let config = ShareConfig(kind: .webDAV, host: "nas.local:5006", share: "remote.php/dav/files/eamon",
                                 username: "eamon", password: "p@ss#1", secure: true)
        let path = "TV/Bob's Burgers/Season 4/What [a] #name? 100%.mkv"
        let url = try XCTUnwrap(config.playbackURL(for: path))
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "nas.local")
        XCTAssertEqual(c.port, 5006)
        XCTAssertEqual(c.user, "eamon")
        XCTAssertEqual(c.password, "p@ss#1")
        XCTAssertEqual(c.path, "/remote.php/dav/files/eamon/" + path)
        XCTAssertNil(c.query)
        XCTAssertNil(c.fragment)

        // Folders get a trailing slash, or servers answer with a redirect.
        XCTAssertEqual(config.url(for: "TV", directory: true)?.absoluteString,
                       "https://nas.local:5006/remote.php/dav/files/eamon/TV/")
        let root = ShareConfig(kind: .webDAV, host: "192.168.8.1", share: "", username: "", password: "")
        XCTAssertEqual(root.url(for: "", directory: true)?.absoluteString, "http://192.168.8.1/")
        XCTAssertEqual(root.playbackURL(for: "a b.mkv")?.absoluteString, "http://192.168.8.1/a%20b.mkv")
        XCTAssertEqual(root.displayName, "192.168.8.1")
        XCTAssertEqual(config.displayName, "eamon")
    }

    func testCompleteness() {
        XCTAssertTrue(ShareConfig(kind: .webDAV, host: "nas", share: "", username: "", password: "").isComplete)
        XCTAssertFalse(ShareConfig(kind: .smb, host: "nas", share: "", username: "", password: "").isComplete)
    }

    /// Apache mod_dav: relative hrefs, "lp1:" prefixes, the folder first.
    func testApacheListing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
        <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
        <D:href>/webdav/TV/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype>
        <lp1:getlastmodified>Wed, 30 Sep 2026 20:26:27 GMT</lp1:getlastmodified></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>/webdav/TV/Bob%27s%20Burgers/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>/webdav/TV/Pilot%20%5B1080p%5D.mkv</D:href>
        <D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>1234567890</lp1:getcontentlength>
        <lp1:getlastmodified>Tue, 01 Sep 2026 08:00:00 GMT</lp1:getlastmodified>
        <D:getcontenttype>video/x-matroska</D:getcontenttype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        </D:multistatus>
        """
        let entries = WebDAVFileSource.entries(multistatus: Data(xml.utf8), requestedPath: "/webdav/TV", folder: "TV")
        XCTAssertEqual(entries.map(\.name), ["Bob's Burgers", "Pilot [1080p].mkv"])
        XCTAssertEqual(entries.map(\.path), ["TV/Bob's Burgers", "TV/Pilot [1080p].mkv"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, false])
        XCTAssertEqual(entries[1].size, 1_234_567_890)
        XCTAssertEqual(entries[1].modified, Date(timeIntervalSince1970: 1_788_249_600))
    }

    /// Nextcloud-style: lowercase "d:" prefix, the folder's href differently
    /// encoded from the request, and a 404 propstat for missing properties.
    func testNextcloudListing() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
        <d:response><d:href>/remote.php/dav/files/eamon/My%20Films/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response>
        <d:response><d:href>/remote.php/dav/files/eamon/My%20Films/Moana%20(2016)/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response>
        </d:multistatus>
        """
        let entries = WebDAVFileSource.entries(multistatus: Data(xml.utf8),
                                               requestedPath: "/remote.php/dav/files/eamon/My Films", folder: "")
        XCTAssertEqual(entries, [FileEntry(name: "Moana (2016)", path: "Moana (2016)", isDirectory: true)])
    }

    /// Absolute hrefs, and a folder entry that doesn't match the request
    /// (a reverse proxy rewrote the path), which goes by position instead.
    func testAbsoluteHrefsAndRewrittenFolder() {
        let xml = """
        <multistatus xmlns="DAV:">
        <response><href>https://nas.example.com/internal/media/</href>
        <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response>
        <response><href>https://nas.example.com/internal/media/a.mp4</href>
        <propstat><prop><resourcetype/><getcontentlength>10</getcontentlength></prop></propstat></response>
        <response><href>https://nas.example.com/internal/media/old</href>
        <propstat><prop><getcontenttype>httpd/unix-directory</getcontenttype></prop></propstat></response>
        </multistatus>
        """
        let entries = WebDAVFileSource.entries(multistatus: Data(xml.utf8), requestedPath: "/media", folder: "media")
        XCTAssertEqual(entries.map(\.path), ["media/a.mp4", "media/old"])
        XCTAssertEqual(entries.map(\.isDirectory), [false, true])
    }

    func testGarbageIsEmpty() {
        let html = Data("<html><body>Index of /</body>".utf8)
        XCTAssertEqual(WebDAVFileSource.entries(multistatus: html, requestedPath: "/", folder: ""), [])
    }

    func testFriendlyErrors() {
        XCTAssertTrue(WebDAVFileSource.error(URLError(.cannotFindHost), host: "nomad").errorDescription!
            .contains("Couldn't find a server"))
        XCTAssertTrue(WebDAVFileSource.error(URLError(.timedOut), host: "nomad").errorDescription!
            .contains("didn't answer"))
        XCTAssertTrue(WebDAVFileSource.error(URLError(.serverCertificateUntrusted), host: "nas").errorDescription!
            .contains("certificate"))
    }
}
