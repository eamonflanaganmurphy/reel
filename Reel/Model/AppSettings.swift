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
/// SMB password in the Keychain.
@Observable
final class AppSettings {
    var host: String { didSet { defaults.set(host, forKey: "host") } }
    var share: String { didSet { defaults.set(share, forKey: "share") } }
    var username: String { didSet { defaults.set(username, forKey: "username") } }
    var password: String { didSet { Keychain.set(password, for: "smb-password") } }
    var tmdbKey: String { didSet { defaults.set(tmdbKey, forKey: "tmdbKey") } }
    var libraries: [LibraryConfig] {
        didSet { defaults.set(try? JSONEncoder().encode(libraries), forKey: "libraries") }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        host = defaults.string(forKey: "host") ?? ""
        share = defaults.string(forKey: "share") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        password = Keychain.get("smb-password") ?? ""
        tmdbKey = defaults.string(forKey: "tmdbKey") ?? ""
        libraries = defaults.data(forKey: "libraries")
            .flatMap { try? JSONDecoder().decode([LibraryConfig].self, from: $0) } ?? LibraryConfig.defaults
    }

    /// Tolerates "smb://host/share" in the address field and "share/folder"
    /// in the share field, the forms the Files app and VLC use.
    var smbConfig: SMBConfig {
        let address = SMBConfig.parse(address: host)
        let shareField = share.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init) ?? ""
        return SMBConfig(host: address.host,
                         share: shareField.isEmpty ? (address.share ?? "") : shareField,
                         username: username.trimmingCharacters(in: .whitespaces),
                         password: password)
    }

    /// Rewrites the address fields into their plain form: moves a share
    /// typed into the address into the share field, and turns a bare
    /// Bonjour name into "<name>.local" when only that resolves. Returns a
    /// note for the user when something changed.
    @MainActor @discardableResult
    func tidyAddress() async -> String? {
        let parsed = SMBConfig.parse(address: host)
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

    func libraryName(for id: UUID) -> String {
        libraries.first { $0.id == id }?.name ?? "Your Library"
    }

    var isConfigured: Bool { smbConfig.isComplete }

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
