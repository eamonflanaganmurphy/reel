import Foundation
import Observation
import ReelCore
import Security

struct LibraryConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Folder inside the share, e.g. "movies" or "TV".
    var path: String
    var kind: LibraryKind
    /// Look titles up on TMDB. Off for YouTube downloads, whose "episodes"
    /// aren't the real ones and would get the wrong names.
    var useTMDB: Bool

    var systemImage: String {
        kind == .movies ? "film" : (useTMDB ? "tv" : "figure.and.child.holdinghands")
    }

    /// Matches the folders on Bucket_A, which the Nomad router mirrors.
    static let defaults: [LibraryConfig] = [
        LibraryConfig(name: "Movies", path: "movies", kind: .movies, useTMDB: true),
        LibraryConfig(name: "TV", path: "TV", kind: .shows, useTMDB: true),
        LibraryConfig(name: "Kids", path: "childrens-shows", kind: .shows, useTMDB: false),
    ]
}

/// Everything the user sets in Settings. Plain values in UserDefaults, the
/// password in the Keychain.
@Observable
final class AppSettings {
    var kind: ShareKind { didSet { defaults.set(kind.rawValue, forKey: "shareKind") } }
    /// The SMB server's address.
    var host: String { didSet { defaults.set(host, forKey: "host") } }
    var share: String { didSet { defaults.set(share, forKey: "share") } }
    /// The WebDAV server's address, path and all. Kept apart from the SMB
    /// fields so switching between the two doesn't lose either.
    var webDAVAddress: String { didSet { defaults.set(webDAVAddress, forKey: "webDAVAddress") } }
    var username: String { didSet { defaults.set(username, forKey: "username") } }
    // The Keychain item's name is from when SMB was the only kind.
    var password: String { didSet { Keychain.set(password, for: "smb-password") } }
    var tmdbKey: String { didSet { defaults.set(tmdbKey, forKey: "tmdbKey") } }
    var libraries: [LibraryConfig] {
        didSet { defaults.set(try? JSONEncoder().encode(libraries), forKey: "libraries") }
    }
    /// Frames taken from the videos go to the share as well as this device,
    /// and frames already there are used, so each is only taken once for
    /// every phone. Off keeps them on this device only. See `SharedFrames`.
    var framesOnShare: Bool { didSet { defaults.set(framesOnShare, forKey: "framesOnShare") } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        kind = defaults.string(forKey: "shareKind").flatMap(ShareKind.init(rawValue:)) ?? .smb
        host = defaults.string(forKey: "host") ?? ""
        share = defaults.string(forKey: "share") ?? ""
        webDAVAddress = defaults.string(forKey: "webDAVAddress") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        password = Keychain.get("smb-password") ?? ""
        tmdbKey = defaults.string(forKey: "tmdbKey") ?? ""
        libraries = defaults.data(forKey: "libraries")
            .flatMap { try? JSONDecoder().decode([LibraryConfig].self, from: $0) } ?? LibraryConfig.defaults
        framesOnShare = defaults.object(forKey: "framesOnShare") as? Bool ?? true
    }

    /// Tolerates "smb://host/share" in the address field and "share/folder"
    /// in the share field, the forms the Files app and VLC use. A WebDAV
    /// address with no scheme gets http at home and https otherwise, the
    /// same guess `tidyAddress` writes back into the field.
    var shareConfig: ShareConfig {
        let user = username.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .smb:
            let address = ShareConfig.parse(address: host)
            let shareField = share.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init) ?? ""
            return ShareConfig(host: address.host,
                               share: shareField.isEmpty ? (address.share ?? "") : shareField,
                               username: user,
                               password: password)
        case .webDAV:
            let address = ShareConfig.parse(webDAVAddress: webDAVAddress)
            return ShareConfig(kind: .webDAV, host: address.host, share: address.path,
                               username: user, password: password,
                               secure: address.secure ?? !ShareConfig.prefersPlainHTTP(host: address.host))
        }
    }

    /// Rewrites the address fields into their plain form: moves a share
    /// typed into the address into the share field, and turns a bare
    /// Bonjour name into "<name>.local" when only that resolves. Returns a
    /// note for the user when something changed.
    @MainActor @discardableResult
    func tidyAddress() async -> String? {
        if kind == .webDAV { return await tidyWebDAVAddress() }
        let parsed = ShareConfig.parse(address: host)
        var notes: [String] = []
        if let s = parsed.share, share.trimmingCharacters(in: .whitespaces).isEmpty {
            share = s
            notes.append("share set to “\(s)”")
        }
        var newHost = parsed.host
        let resolved = await HostResolver.bestHost(newHost)
        if resolved != newHost {
            notes.append("using “\(resolved)”")
            newHost = resolved
        }
        if newHost != host { host = newHost }
        return notes.isEmpty ? nil : "Address tidied: " + notes.joined(separator: ", ") + "."
    }

    /// Writes the WebDAV address out in full, "http(s)://host/path", so
    /// it's plain which scheme is in use, with a Bonjour name made
    /// resolvable as for SMB.
    @MainActor
    private func tidyWebDAVAddress() async -> String? {
        let parsed = ShareConfig.parse(webDAVAddress: webDAVAddress)
        guard !parsed.host.isEmpty else { return nil }
        var notes: [String] = []
        let host = await HostResolver.bestHost(parsed.host)
        if host != parsed.host { notes.append("using “\(host)”") }
        let secure = parsed.secure ?? !ShareConfig.prefersPlainHTTP(host: host)
        if parsed.secure == nil { notes.append(secure ? "using https" : "using http") }
        let tidy = (secure ? "https://" : "http://") + host + (parsed.path.isEmpty ? "" : "/" + parsed.path)
        if tidy != webDAVAddress { webDAVAddress = tidy }
        return notes.isEmpty ? nil : "Address tidied: " + notes.joined(separator: ", ") + "."
    }

    func libraryName(for id: UUID) -> String {
        libraries.first { $0.id == id }?.name ?? "Your Library"
    }

    var isConfigured: Bool { shareConfig.isComplete }

    func library(_ id: UUID) -> LibraryConfig? { libraries.first { $0.id == id } }
}

enum Keychain {
    private static let service = "me.eamonmurphy.reel"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
