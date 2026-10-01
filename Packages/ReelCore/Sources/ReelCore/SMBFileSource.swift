import AMSMB2
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ShareConfig {
    var smbServerURL: URL? { URL(string: "smb://\(host)") }

    /// No username means a guest login, as the Files app does.
    var smbCredential: URLCredential {
        URLCredential(user: username.isEmpty ? "guest" : username, password: password, persistence: .forSession)
    }
}

/// One connection to one share. AMSMB2 queues requests internally, so a
/// single instance can be shared across tasks.
///
/// Each session gets its own `SMB2Manager`, connected once before anything
/// uses it. AMSMB2 swaps a manager's client in `connectShare` (when the old
/// one doesn't answer) without stopping requests on its concurrent queue
/// from reading it at the same time, which crashes in libsmb2 or in a
/// release. That's just what happens on coming back from the background,
/// when the posters, the progress pull and the scan all start at once on a
/// session iOS has since closed. A fresh manager per session means a client
/// is never replaced under a running request; ones still using the old
/// session keep it alive until they finish.
public final class SMBFileSource: ShareSource, @unchecked Sendable {
    public let config: ShareConfig
    private let url: URL
    private let lock = NSLock()
    // Guarded by lock. Concurrent callers share one connection attempt.
    private var session: Session?

    private struct Session {
        let manager: SMB2Manager
        let ready: Task<Void, any Error>
    }

    public init(config: ShareConfig) throws {
        guard let url = config.smbServerURL,
              SMB2Manager(url: url, domain: config.domain, credential: config.smbCredential) != nil
        else { throw ShareError.invalidHost(config.host) }
        self.config = config
        self.url = url
    }

    deinit {
        Self.release(session)
    }

    /// Share names on the server, for the settings screen.
    public static func listShares(config: ShareConfig) async throws -> [String] {
        guard let url = config.smbServerURL,
              let manager = SMB2Manager(url: url, domain: config.domain, credential: config.smbCredential)
        else { throw ShareError.invalidHost(config.host) }
        do {
            return try await manager.listShares().map(\.name).filter { !$0.hasSuffix("$") }
        } catch {
            let (code, detail) = ShareError.code(of: error)
            throw ShareError.server(host: config.host, code: code, detail: detail)
        }
    }

    private func connect() async throws -> SMB2Manager {
        let session = try lock.withLock {
            if let session { return session }
            guard let manager = SMB2Manager(url: url, domain: config.domain, credential: config.smbCredential)
            else { throw ShareError.invalidHost(config.host) }
            manager.timeout = 20
            let share = config.share, host = config.host
            let ready = Task {
                do {
                    try await manager.connectShare(name: share)
                } catch {
                    // libsmb2 connects and opens the share in one call; a
                    // missing share is ENOENT/ENODEV, anything else is the server.
                    let (code, detail) = ShareError.code(of: error)
                    if code == ENOENT || code == ENODEV || detail.contains("BAD_NETWORK_NAME") {
                        throw ShareError.share(name: share, code: code, detail: detail)
                    }
                    throw ShareError.server(host: host, code: code, detail: detail)
                }
            }
            let new = Session(manager: manager, ready: ready)
            self.session = new
            return new
        }
        do {
            try await session.ready.value
        } catch {
            drop(session.manager)
            throw error
        }
        return session.manager
    }

    /// Runs `operation` on the open session. libsmb2 never reconnects by
    /// itself, so a session that died since it was opened (iOS reclaims a
    /// suspended app's sockets, the phone changed network, the router
    /// restarted) is replaced and the operation tried once more.
    private func withConnection<T>(_ operation: (SMB2Manager) async throws -> T) async throws -> T {
        let manager = try await connect()
        do {
            return try await operation(manager)
        } catch let error where Self.isConnectionError(ShareError.code(of: error).0) {
            // Requests that failed together start one new session between them.
            drop(manager)
            return try await operation(try await connect())
        }
    }

    /// Forgets `manager`'s session, unless it has already been replaced.
    private func drop(_ manager: SMB2Manager) {
        let old: Session? = lock.withLock {
            guard let session, session.manager === manager else { return nil }
            defer { self.session = nil }
            return session
        }
        Self.release(old)
    }

    /// A manager's last release closes its session, waiting on the server
    /// for up to its timeout when the socket has died, so it never happens on
    /// the caller's thread, which may be the main one.
    private static func release(_ session: Session?) {
        guard let session else { return }
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(session) {} }
    }

    static func isConnectionError(_ code: Int32) -> Bool {
        [ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, EBADF,
         ENETDOWN, ENETUNREACH, ENETRESET, EHOSTUNREACH, EHOSTDOWN].contains(code)
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let base = Self.normalize(path)
        let items: [[URLResourceKey: Any]]
        do {
            items = try await withConnection { try await $0.contentsOfDirectory(atPath: base) }
        } catch let error as ShareError {
            throw error
        } catch {
            let (code, detail) = ShareError.code(of: error)
            // A lost connection isn't the folder's fault, and callers treat
            // folder errors as "wrong folder" or "nothing there yet".
            if Self.isConnectionError(code) { throw ShareError.server(host: config.host, code: code, detail: detail) }
            throw ShareError.folder(path: base.isEmpty ? "/" : base, code: code, detail: detail)
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

    public func read(_ path: String, maxBytes: UInt64) async throws -> Data {
        let path = Self.normalize(path)
        return try await withConnection { manager in
            try await manager.contents(atPath: path, range: 0..<maxBytes, progress: nil)
        }
    }

    /// Writes a small file, creating its folders. It goes to a temporary name
    /// first and is renamed into place, so a reader never sees half of it.
    public func replace(_ path: String, with data: Data) async throws {
        let path = Self.normalize(path)
        try await withConnection { manager in
            var folder = ""
            for part in path.split(separator: "/").dropLast() {
                folder = folder.isEmpty ? String(part) : "\(folder)/\(part)"
                // Already there is the usual case; a real problem (a read-only
                // login) shows up in the write below.
                try? await manager.createDirectory(atPath: folder)
            }
            let temp = Self.temporaryName(for: path)
            do {
                try await manager.write(data: data, toPath: temp, progress: nil)
                try? await manager.removeItem(atPath: path)
                try await manager.moveItem(atPath: temp, toPath: path)
            } catch {
                // Nothing else will ever tidy up a name only this write used.
                try? await manager.removeItem(atPath: temp)
                throw error
            }
        }
    }

    /// Makes the next request start a new session, e.g. after the app has
    /// been suspended and its socket may have been closed.
    public func invalidate() {
        let old: Session? = lock.withLock {
            defer { session = nil }
            return session
        }
        Self.release(old)
    }

    public func disconnect() async {
        let old: Session? = lock.withLock {
            defer { session = nil }
            return session
        }
        guard let old, (try? await old.ready.value) != nil else { return }
        try? await old.manager.disconnectShare(gracefully: true)
    }

    static func normalize(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}
