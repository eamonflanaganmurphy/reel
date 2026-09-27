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

    var serverURL: URL? { URL(string: "smb://\(host)") }

    var credential: URLCredential? {
        username.isEmpty ? nil : URLCredential(user: username, password: password, persistence: .forSession)
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

public enum SMBError: LocalizedError {
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost(let h): "\"\(h)\" isn't a valid SMB host."
        }
    }
}

/// One connection to one share. AMSMB2 queues requests internally, so a
/// single instance can be shared across tasks.
public final class SMBFileSource: FileSource, @unchecked Sendable {
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
        return try await manager.listShares().map(\.name).filter { !$0.hasSuffix("$") }
    }

    private func connect() async throws {
        let task = lock.withLock {
            if let connection { return connection }
            let manager = manager, share = config.share
            let t = Task { try await manager.connectShare(name: share) }
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

    public func list(_ path: String) async throws -> [FileEntry] {
        try await connect()
        let items = try await manager.contentsOfDirectory(atPath: Self.normalize(path))
        return items.compactMap { item -> FileEntry? in
            guard let name = item[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDir = (item[.isDirectoryKey] as? Bool) ?? false
            let size = (item[.fileSizeKey] as? Int64) ?? Int64((item[.fileSizeKey] as? Int) ?? 0)
            let base = Self.normalize(path)
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
        try await connect()
        return try await manager.contents(atPath: Self.normalize(path), range: 0..<maxBytes, progress: nil)
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
