import Foundation

/// How Reel talks to the server.
public enum ShareKind: String, Codable, CaseIterable, Sendable {
    /// Windows file sharing: routers, NASes, Macs and Windows PCs.
    case smb
    /// File sharing over HTTP: Nextcloud, Synology and QNAP, rclone, Apache and nginx.
    case webDAV = "webdav"

    public var name: String {
        switch self {
        case .smb: "SMB"
        case .webDAV: "WebDAV"
        }
    }
}

public struct ShareConfig: Codable, Hashable, Sendable {
    public var kind: ShareKind
    /// Host or IP, optionally with a port: "192.168.8.1" or "nomad.local:445".
    public var host: String
    /// The SMB share. For WebDAV, the path on the server the files are
    /// under, e.g. "remote.php/dav/files/eamon", or empty for the root.
    public var share: String
    public var username: String
    public var password: String
    public var domain: String
    /// WebDAV over https rather than http.
    public var secure: Bool

    public init(kind: ShareKind = .smb, host: String, share: String, username: String, password: String,
                domain: String = "", secure: Bool = false) {
        self.kind = kind
        self.host = host
        self.share = share
        self.username = username
        self.password = password
        self.domain = domain
        self.secure = secure
    }

    /// A WebDAV server's root is a fine place for the libraries; an SMB
    /// server's isn't, since everything is in a share.
    public var isComplete: Bool { !host.isEmpty && (kind == .webDAV || !share.isEmpty) }

    /// What to call the top of the share in the folder browsers.
    public var displayName: String {
        share.split(separator: "/").last.map(String.init) ?? host
    }

    /// Accepts the address however it was typed or pasted: "192.168.8.1",
    /// "smb://nomad.local/media", "\\\\nomad\\media\\movies", "user@host/share".
    /// Anything after the host is returned as a share and a folder path.
    public static func parse(address raw: String) -> (host: String, share: String?, path: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        for scheme in ["smb://", "cifs://", "afp://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        while s.hasPrefix("/") { s.removeFirst() }
        var parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return ("", nil, nil) }
        var host = parts.removeFirst()
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        let share = parts.isEmpty ? nil : parts.removeFirst()
        let path = parts.isEmpty ? nil : parts.joined(separator: "/")
        return (host, share?.removingPercentEncoding ?? share, path?.removingPercentEncoding ?? path)
    }

    /// Accepts a WebDAV address in the forms servers and other apps give
    /// it: "https://nas.local:5006/video", "davs://cloud.example.com/remote.php/dav/files/eamon/",
    /// "192.168.8.1/webdav". `secure` is nil when no scheme was given.
    public static func parse(webDAVAddress raw: String) -> (host: String, path: String, secure: Bool?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var secure: Bool?
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            if ["https", "davs", "webdavs"].contains(scheme) { secure = true }
            if ["http", "dav", "webdav"].contains(scheme) { secure = false }
            s = String(s[r.upperBound...])
        }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        var parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return ("", "", secure) }
        var host = parts.removeFirst()
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        let path = parts.joined(separator: "/")
        return (host, path.removingPercentEncoding ?? path, secure)
    }

    /// With no scheme typed, https is the safe guess for a server on the
    /// internet, but home servers at an IP or a Bonjour name almost never
    /// have a certificate.
    public static func prefersPlainHTTP(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("[") { return true } // IPv6 literal
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        let isIPv4 = name.split(separator: ".").count == 4 && name.allSatisfy { $0.isNumber || $0 == "." }
        return isIPv4 || name.hasSuffix(".local") || !name.contains(".")
    }

    /// URL for the player. Credentials are embedded because that's what
    /// VLC's smb2 and http modules read first; the URL never leaves the device.
    public func playbackURL(for path: String) -> URL? {
        url(for: path, withCredentials: true)
    }

    /// The URL of a file or folder on the share: smb://host/share/path or
    /// http(s)://host/base/path.
    func url(for path: String, withCredentials: Bool = false, directory: Bool = false) -> URL? {
        var c = URLComponents()
        switch kind {
        case .smb: c.scheme = "smb"
        case .webDAV: c.scheme = secure ? "https" : "http"
        }
        let hostParts = host.split(separator: ":", maxSplits: 1)
        c.host = String(hostParts.first ?? "")
        if hostParts.count == 2 { c.port = Int(hostParts[1]) }
        if withCredentials, !username.isEmpty {
            c.percentEncodedUser = Self.encode(username)
            c.percentEncodedPassword = Self.encode(password)
        }
        let components = (share + "/" + path).split(separator: "/").map(String.init)
        var encoded = "/" + components.map(Self.encode).joined(separator: "/")
        if directory, !components.isEmpty { encoded += "/" }
        c.percentEncodedPath = encoded
        return c.url
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Everything but RFC 3986 unreserved characters gets escaped, so names
    /// with "#", "?", "[", "%" or emoji survive the round trip.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// A connection to the share this describes.
    public func makeSource() throws -> any ShareSource {
        switch kind {
        case .smb: try SMBFileSource(config: self)
        case .webDAV: try WebDAVFileSource(config: self)
        }
    }
}

/// A share the app can browse, read, and keep watch progress on.
public protocol ShareSource: FileSource, ProgressStorage {
    var config: ShareConfig { get }
    /// Makes the next request check the connection is still alive (and
    /// reconnect if not), e.g. after the app has been suspended.
    func invalidate()
    func disconnect() async
}

extension ShareSource {
    /// Whole-file read for small things: subtitles and thumbnails.
    public func read(_ path: String) async throws -> Data {
        try await read(path, maxBytes: 20_000_000)
    }
}

/// A failure with enough context to tell the user what to fix. Codes are
/// errno values, which is what libsmb2 reports everything as; WebDAV's HTTP
/// statuses and URL errors are translated to the same. Some are misleading
/// on their own: an SMB wrong password arrives as ECONNREFUSED, an unknown
/// hostname as EIO.
public enum ShareError: LocalizedError {
    case invalidHost(String)
    /// Couldn't reach or log in to the server.
    case server(host: String, code: Int32, detail: String)
    /// Logged in, but the share wouldn't open.
    case share(name: String, code: Int32, detail: String)
    /// A folder inside the share couldn't be listed.
    case folder(path: String, code: Int32, detail: String)
    /// The path in a WebDAV address doesn't exist on the server.
    case missingPath(host: String, path: String)
    /// Something answered over HTTP, but not as a WebDAV server.
    case notWebDAV(host: String)
    /// The https certificate isn't one iOS trusts, e.g. a NAS's self-signed one.
    case untrustedCertificate(host: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost(let h):
            return "“\(h)” isn't a valid server address."
        case .server(let host, let code, let detail):
            switch code {
            case ECONNREFUSED, EACCES, EPERM:
                return "\(host) refused the login. Check the username and password (leave both empty for guest access)."
            case EIO where detail.localizedCaseInsensitiveContains("resolve"):
                return "Couldn't find a server called “\(host)”. Try its IP address, or pick it under Nearby Servers."
            case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
                return "\(host) didn't answer. Are you on the router's network, and has Reel been allowed Local Network access?"
            default:
                return "Couldn't connect to \(host): \(detail) (\(code))"
            }
        case .share(let name, let code, let detail):
            switch code {
            case ENOENT, ENODEV:
                return "The server has no share called “\(name)”. Clear the Share field and test again to list them."
            case EACCES, EPERM, ECONNREFUSED:
                return "This login isn't allowed to open the share “\(name)”."
            default:
                return "Couldn't open the share “\(name)”: \(detail) (\(code))"
            }
        case .folder(let path, let code, let detail):
            switch code {
            case ENOENT, ENOTDIR:
                return "There's no folder “\(path)” in the share."
            case EACCES, EPERM:
                return "This login isn't allowed to open “\(path)”."
            default:
                return "Couldn't list “\(path)”: \(detail) (\(code))"
            }
        case .missingPath(let host, let path):
            return "\(host) has nothing at “/\(path)”. Check the path in the address."
        case .notWebDAV(let host):
            return "\(host) answered, but not as a WebDAV server. Check the address, including its port and path."
        case .untrustedCertificate(let host):
            return "\(host)'s certificate isn't trusted by iOS. Use http:// on your own network, or give the server a real certificate."
        }
    }

    static func code(of error: any Error) -> (Int32, String) {
        let ns = error as NSError
        let code = ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : -1
        return (code, ns.localizedDescription)
    }
}

/// Bare names like "nomad" only resolve through Bonjour as "nomad.local".
public enum HostResolver {
    public static func resolves(_ host: String) -> Bool {
        let name = host.split(separator: ":").first.map(String.init) ?? host
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(name, nil, nil, &result)
        if let result { freeaddrinfo(result) }
        return rc == 0
    }

    /// The host itself if it resolves, else "<host>.local" if that does.
    public static func bestHost(_ host: String) async -> String {
        await Task.detached {
            if resolves(host) { return host }
            let isBareName = !host.contains(".") && !host.contains(":")
            if isBareName, resolves(host + ".local") { return host + ".local" }
            return host
        }.value
    }
}
