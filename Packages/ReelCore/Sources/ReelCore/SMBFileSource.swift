import AMSMB2
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SMBConfig: Codable, Hashable, Sendable {
    /// Host or IP, optionally with a port: "192.168.8.1" or "nomad.local:445".
    public var host: String
    public var share: String
    public var username: String
    public var password: String
    public var domain: String

    public init(host: String, share: String, username: String, password: String, domain: String = "") {
        self.host = host
        self.share = share
        self.username = username
        self.password = password
        self.domain = domain
    }

    public var isComplete: Bool { !host.isEmpty && !share.isEmpty }

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

    var serverURL: URL? { URL(string: "smb://\(host)") }

    /// No username means a guest login, as the Files app does.
    var credential: URLCredential {
        URLCredential(user: username.isEmpty ? "guest" : username, password: password, persistence: .forSession)
    }

    /// smb:// URL for the player. Credentials are embedded because that's what
    /// VLC's smb2 module reads first; the URL never leaves the device.
    public func playbackURL(for path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "smb"
        let hostParts = host.split(separator: ":", maxSplits: 1)
        c.host = String(hostParts.first ?? "")
        if hostParts.count == 2 { c.port = Int(hostParts[1]) }
        if !username.isEmpty {
            c.percentEncodedUser = Self.encode(username)
            c.percentEncodedPassword = Self.encode(password)
        }
        let components = [share] + path.split(separator: "/").map(String.init)
        c.percentEncodedPath = "/" + components.map(Self.encode).joined(separator: "/")
        return c.url
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Everything but RFC 3986 unreserved characters gets escaped, so names
    /// with "#", "?", "[", "%" or emoji survive the round trip.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

/// A failure with enough context to tell the user what to fix. libsmb2
/// reports everything as errno values, and some are misleading on their own:
/// a wrong password arrives as ECONNREFUSED, an unknown hostname as EIO.
public enum SMBError: LocalizedError {
    case invalidHost(String)
    /// Couldn't reach or log in to the server.
    case server(host: String, code: Int32, detail: String)
    /// Logged in, but the share wouldn't open.
    case share(name: String, code: Int32, detail: String)
    /// A folder inside the share couldn't be listed.
    case folder(path: String, code: Int32, detail: String)

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
            default:
                return "Couldn't list “\(path)”: \(detail) (\(code))"
            }
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

/// One connection to one share. AMSMB2 queues requests internally, so a
/// single instance can be shared across tasks.
public final class SMBFileSource: FileSource, ProgressStorage, @unchecked Sendable {
    public let config: SMBConfig
    private let manager: SMB2Manager
    private let lock = NSLock()
    // Guarded by lock. Concurrent callers share one connection attempt.
    private var connection: Task<Void, any Error>?

    public init(config: SMBConfig) throws {
        guard let url = config.serverURL,
              let manager = SMB2Manager(url: url, domain: config.domain, credential: config.credential)
        else { throw SMBError.invalidHost(config.host) }
        self.config = config
        self.manager = manager
        manager.timeout = 20
    }

    /// Share names on the server, for the settings screen.
    public static func listShares(config: SMBConfig) async throws -> [String] {
        guard let url = config.serverURL,
              let manager = SMB2Manager(url: url, domain: config.domain, credential: config.credential)
        else { throw SMBError.invalidHost(config.host) }
        do {
            return try await manager.listShares().map(\.name).filter { !$0.hasSuffix("$") }
        } catch {
            let (code, detail) = SMBError.code(of: error)
            throw SMBError.server(host: config.host, code: code, detail: detail)
        }
    }

    private func connect() async throws {
        let task = lock.withLock {
            if let connection { return connection }
            let manager = manager, share = config.share, host = config.host
            let t = Task {
                do {
                    try await manager.connectShare(name: share)
                } catch {
                    // libsmb2 connects and opens the share in one call; a
                    // missing share is ENOENT/ENODEV, anything else is the server.
                    let (code, detail) = SMBError.code(of: error)
                    if code == ENOENT || code == ENODEV || detail.contains("BAD_NETWORK_NAME") {
                        throw SMBError.share(name: share, code: code, detail: detail)
                    }
                    throw SMBError.server(host: host, code: code, detail: detail)
                }
            }
            connection = t
            return t
        }
        do {
            try await task.value
        } catch {
            lock.withLock { connection = nil }
            throw error
        }
    }

    /// Runs `operation` on the open session. libsmb2 never reconnects by
    /// itself and AMSMB2 only does in `connectShare`, so a session that died
    /// since it was opened (iOS reclaims a suspended app's sockets, the
    /// phone changed network, the router restarted) is reopened and the
    /// operation tried once more.
    private func withConnection<T>(_ operation: () async throws -> T) async throws -> T {
        try await connect()
        do {
            return try await operation()
        } catch let error where Self.isConnectionError(SMBError.code(of: error).0) {
            invalidate()
            try await connect()
            return try await operation()
        }
    }

    static func isConnectionError(_ code: Int32) -> Bool {
        [ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, EBADF,
         ENETDOWN, ENETUNREACH, ENETRESET, EHOSTUNREACH, EHOSTDOWN].contains(code)
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let base = Self.normalize(path)
        let items: [[URLResourceKey: Any]]
        do {
            items = try await withConnection { try await manager.contentsOfDirectory(atPath: base) }
        } catch let error as SMBError {
            throw error
        } catch {
            let (code, detail) = SMBError.code(of: error)
            // A lost connection isn't the folder's fault, and callers treat
            // folder errors as "wrong folder" or "nothing there yet".
            if Self.isConnectionError(code) { throw SMBError.server(host: config.host, code: code, detail: detail) }
            throw SMBError.folder(path: base.isEmpty ? "/" : base, code: code, detail: detail)
        }
        return items.compactMap { item -> FileEntry? in
            guard let name = item[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDir = (item[.isDirectoryKey] as? Bool) ?? false
            let size = (item[.fileSizeKey] as? Int64) ?? Int64((item[.fileSizeKey] as? Int) ?? 0)
            return FileEntry(
                name: name,
                path: base.isEmpty ? name : "\(base)/\(name)",
                isDirectory: isDir,
                size: size,
                modified: item[.contentModificationDateKey] as? Date
            )
        }
    }

    /// Whole-file read for small things: subtitles and thumbnails.
    public func read(_ path: String, maxBytes: UInt64 = 20_000_000) async throws -> Data {
        let path = Self.normalize(path)
        return try await withConnection {
            try await manager.contents(atPath: path, range: 0..<maxBytes, progress: nil)
        }
    }

    /// Writes a small file, creating its folders. It goes to a temporary name
    /// first and is renamed into place, so a reader never sees half of it.
    public func replace(_ path: String, with data: Data) async throws {
        let path = Self.normalize(path)
        try await withConnection {
            var folder = ""
            for part in path.split(separator: "/").dropLast() {
                folder = folder.isEmpty ? String(part) : "\(folder)/\(part)"
                // Already there is the usual case; a real problem (a read-only
                // login) shows up in the write below.
                try? await manager.createDirectory(atPath: folder)
            }
            let temp = path + ".tmp"
            try? await manager.removeItem(atPath: temp)
            try await manager.write(data: data, toPath: temp, progress: nil)
            try? await manager.removeItem(atPath: path)
            try await manager.moveItem(atPath: temp, toPath: path)
        }
    }

    /// Makes the next request check the session is still alive (and open a
    /// new one if not), e.g. after the app has been suspended.
    public func invalidate() {
        lock.withLock { connection = nil }
    }

    public func disconnect() async {
        let wasConnected = lock.withLock {
            defer { connection = nil }
            return connection != nil
        }
        if wasConnected { try? await manager.disconnectShare() }
    }

    static func normalize(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}
