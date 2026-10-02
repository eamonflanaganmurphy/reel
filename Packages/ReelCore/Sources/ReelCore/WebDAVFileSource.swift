import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A share served over WebDAV: Nextcloud and ownCloud, Synology and QNAP,
/// rclone serve, Apache and nginx. It's plain HTTP, so there's no session
/// to keep alive, and VLC plays the files from the same URLs.
public final class WebDAVFileSource: ShareSource, Sendable {
    public let config: ShareConfig
    private let session: URLSession
    private let authorization: String?

    public init(config: ShareConfig) throws {
        guard !config.host.isEmpty, config.url(for: "") != nil else { throw ShareError.invalidHost(config.host) }
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A router's web server is as easily swamped as its Samba.
        configuration.httpMaximumConnectionsPerHost = 2
        let credential = config.username.isEmpty ? nil
            : URLCredential(user: config.username, password: config.password, persistence: .forSession)
        session = URLSession(configuration: configuration, delegate: Challenges(credential: credential), delegateQueue: nil)
        // Nearly every WebDAV server uses Basic auth. Sending it up front
        // saves waiting for a 401 before each of the hundreds of requests a
        // scan makes; a server wanting Digest still gets it via Challenges.
        authorization = config.username.isEmpty ? nil
            : "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    deinit {
        // The session holds its delegate until it's invalidated.
        session.finishTasksAndInvalidate()
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let base = Self.normalize(path)
        var request = try request(base, method: "PROPFIND", directory: true)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, status) = try await send(request)
        switch status {
        case 207:
            let serverPath = "/" + (config.share + "/" + base).split(separator: "/").joined(separator: "/")
            return Self.entries(multistatus: data, requestedPath: serverPath, folder: base)
        case 404 where base.isEmpty, 409 where base.isEmpty:
            throw ShareError.missingPath(host: config.host, path: config.share)
        default:
            throw error(status: status, path: base)
        }
    }

    public func read(_ path: String, range: Range<UInt64>) async throws -> Data {
        let path = Self.normalize(path)
        guard !range.isEmpty else { return Data() }
        var request = try request(path, method: "GET")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, status) = try await send(request)
        guard let piece = try Self.piece(of: data, status: status, range: range, host: config.host) else {
            throw error(status: status, path: path)
        }
        return piece
    }

    /// What a ranged GET's answer holds of `range`, or nil for an error
    /// status. A server that ignores Range sends the whole file with a 200,
    /// which only does for a read from the start. Asking from past the end
    /// gets a 416.
    static func piece(of data: Data, status: Int, range: Range<UInt64>, host: String) throws -> Data? {
        switch status {
        case 206:
            return data.count > range.count ? data.prefix(range.count) : data
        case 200 where range.lowerBound == 0:
            return data.count > range.count ? data.prefix(range.count) : data
        case 200:
            throw ShareError.noPartialReads(host: host)
        case 416:
            return Data()
        default:
            return nil
        }
    }

    /// Writes a small file, creating its folders. It goes to a temporary name
    /// first and is moved into place, so a reader never sees half of it.
    public func replace(_ path: String, with data: Data) async throws {
        let path = Self.normalize(path)
        var folder = ""
        for part in path.split(separator: "/").dropLast() {
            folder = folder.isEmpty ? String(part) : "\(folder)/\(part)"
            // 405 means it's already there, the usual case; a real problem
            // (a read-only login) shows up in the write below.
            _ = try? await send(request(folder, method: "MKCOL", directory: true))
        }
        let temp = Self.temporaryName(for: path)
        var put = try request(temp, method: "PUT")
        put.httpBody = data
        let (_, putStatus) = try await send(put)
        guard (200..<300).contains(putStatus) else { throw error(status: putStatus, path: path) }

        var move = try request(temp, method: "MOVE")
        move.setValue(config.url(for: path)?.absoluteString, forHTTPHeaderField: "Destination")
        move.setValue("T", forHTTPHeaderField: "Overwrite")
        if let (_, status) = try? await send(move), (200..<300).contains(status) { return }
        // Some servers won't MOVE; a plain overwrite is nearly as good.
        _ = try? await send(request(temp, method: "DELETE"))
        put.url = config.url(for: path)
        let (_, status) = try await send(put)
        guard (200..<300).contains(status) else { throw error(status: status, path: path) }
    }

    /// HTTP has no session to lose.
    public func invalidate() {}

    public func disconnect() async {}

    // MARK: Requests

    private func request(_ path: String, method: String, directory: Bool = false) throws -> URLRequest {
        guard let url = config.url(for: path, directory: directory) else { throw ShareError.invalidHost(config.host) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
            // Nobody stopped waiting, so it was Challenges giving up on the login.
            throw ShareError.server(host: config.host, code: EACCES, detail: "Login refused")
        } catch let error as URLError {
            throw Self.error(error, host: config.host)
        }
    }

    /// An HTTP status as the same errors the SMB share gives, so the
    /// scanner and the app treat both alike.
    private func error(status: Int, path: String) -> ShareError {
        let shown = path.isEmpty ? "/" : path
        switch status {
        case 401:
            return .server(host: config.host, code: EACCES, detail: "HTTP 401")
        case 403:
            return .folder(path: shown, code: EACCES, detail: "HTTP 403")
        case 404, 409, 410:
            return .folder(path: shown, code: ENOENT, detail: "HTTP \(status)")
        case 200, 301, 302, 405, 501:
            // A web page, a redirect to a login, or no PROPFIND at all.
            return .notWebDAV(host: config.host)
        default:
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            return .server(host: config.host, code: -1, detail: "HTTP \(status) \(reason)")
        }
    }

    static func error(_ error: URLError, host: String) -> ShareError {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .server(host: host, code: EIO, detail: "Can not resolve \(host)")
        case .timedOut:
            return .server(host: host, code: ETIMEDOUT, detail: error.localizedDescription)
        case .cannotConnectToHost, .notConnectedToInternet:
            return .server(host: host, code: EHOSTUNREACH, detail: error.localizedDescription)
        case .networkConnectionLost:
            return .server(host: host, code: ECONNRESET, detail: error.localizedDescription)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .server(host: host, code: EACCES, detail: error.localizedDescription)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .untrustedCertificate(host: host)
        default:
            return .server(host: host, code: -1, detail: error.localizedDescription)
        }
    }

    static func normalize(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }

    // MARK: Listings

    private static let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><getlastmodified/><getcontenttype/></prop></propfind>
        """

    /// The folder's contents from a PROPFIND response. `requestedPath` is
    /// the folder's decoded path on the server, which identifies the entry
    /// for the folder itself; `folder` is its path in the share.
    static func entries(multistatus data: Data, requestedPath: String, folder: String) -> [FileEntry] {
        let parser = XMLParser(data: data)
        let reader = MultistatusReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return [] }

        var responses = reader.responses
        let requested = serverPath(ofHref: requestedPath)
        if let own = responses.firstIndex(where: { serverPath(ofHref: $0.href) == requested }) {
            responses.remove(at: own)
        } else if responses.first?.isCollection == true {
            // Servers list the folder itself first. Its href didn't match,
            // e.g. a proxy in front rewrote the path, so go by position.
            responses.removeFirst()
        }
        return responses.compactMap { r in
            guard let name = serverPath(ofHref: r.href).split(separator: "/").last.map(String.init),
                  name != ".", name != ".." else { return nil }
            return FileEntry(name: name, path: folder.isEmpty ? name : "\(folder)/\(name)",
                             isDirectory: r.isCollection, size: r.size, modified: r.modified)
        }
    }

    /// "/dav/My%20Films/" or "https://host/dav/My%20Films" as "/dav/My Films".
    static func serverPath(ofHref href: String) -> String {
        var s = Substring(href)
        if let scheme = s.range(of: "://") {
            let rest = s[scheme.upperBound...]
            s = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let query = s.firstIndex(of: "?") { s = s[..<query] }
        let decoded = s.removingPercentEncoding ?? String(s)
        return "/" + decoded.split(separator: "/").joined(separator: "/")
    }
}

/// Answers the server's login challenge when it wants more than the Basic
/// auth sent up front, e.g. Digest.
private final class Challenges: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential?

    init(credential: URLCredential?) {
        self.credential = credential
    }

    #if canImport(FoundationNetworking)
    private static let logins = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest]
    #else
    private static let logins = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                 NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault]
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Certificates are left to the system.
        guard Self.logins.contains(challenge.protectionSpace.authenticationMethod) else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if let credential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            // A second try with the same login would fail the same way.
            // Cancelling ends the request as a login error.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Pulls the few properties Reel asks for out of a 207 Multi-Status body.
/// Namespace prefixes vary by server ("D:", "d:", "lp1:"), so elements are
/// matched by local name.
private final class MultistatusReader: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var isCollection = false
        var size: Int64 = 0
        var modified: Date?
    }

    private(set) var responses: [Response] = []
    private var current: Response?
    private var text = ""
    private var inResourceType = false
    private var inProp = false

    private let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = Response()
        case "prop": inProp = true
        case "resourcetype": inResourceType = true
        case "collection" where inResourceType: current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        // The response's own href, not one inside a property.
        case "href" where !inProp: current?.href = value
        case "prop": inProp = false
        case "resourcetype": inResourceType = false
        case "getcontentlength": current?.size = Int64(value) ?? 0
        case "getlastmodified": current?.modified = httpDate.date(from: value)
        case "getcontenttype" where value == "httpd/unix-directory": current?.isCollection = true
        case "response":
            if let current, !current.href.isEmpty { responses.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}
