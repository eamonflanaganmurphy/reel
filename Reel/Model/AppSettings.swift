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

extension CollectionConfig {
    /// The Kids & Family collection every install starts with. The same ID
    /// everywhere, so each phone's copy is one collection once synced.
    static let starterID = UUID(uuidString: "6B1D5A10-0C2E-4F6A-9B7E-2A51F0C0FFEE")!

    /// Kids' movies and shows, with any library named for kids thrown in,
    /// since those often aren't on TMDB. The starter is dated long ago, so
    /// another phone's edits to it win over a fresh install's copy.
    static func kidsAndFamily(libraries: [LibraryConfig], starter: Bool = false) -> CollectionConfig {
        var rules = CollectionRules.kidsAndFamily
        let kids = libraries.filter { $0.name.localizedCaseInsensitiveContains("kid") || $0.path.localizedCaseInsensitiveContains("child") }
        if !kids.isEmpty { rules.filters.insert(.libraries(Set(kids.map(\.path))), at: 0) }
        return starter
            ? CollectionConfig(id: starterID, name: "Kids & Family", rules: rules, updatedAt: longAgo)
            : CollectionConfig(name: "Kids & Family", rules: rules)
    }
}

/// A library's or collection's tab.
enum TabItem: Identifiable {
    case collection(CollectionConfig)
    case library(LibraryConfig)

    var id: UUID {
        switch self {
        case .collection(let c): c.id
        case .library(let l): l.id
        }
    }
    var name: String {
        switch self {
        case .collection(let c): c.name
        case .library(let l): l.name
        }
    }
    var systemImage: String {
        switch self {
        case .collection: "square.stack"
        case .library(let l): l.systemImage
        }
    }
}

extension Notification.Name {
    /// Posted when collections are changed on this device, to share them.
    static let collectionsChanged = Notification.Name("collectionsChanged")
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
    /// Shared with every phone through the share; see `CollectionSync`.
    /// Change them with `save` and `deleteCollection`, which date the change.
    private(set) var collections: [CollectionConfig] {
        didSet { defaults.set(try? JSONEncoder().encode(collections), forKey: "collections") }
    }
    /// Collections deleted, and when, so other phones' copies don't bring them back.
    private(set) var deletedCollections: [UUID: Date] {
        didSet { defaults.set(try? JSONEncoder().encode(deletedCollections), forKey: "deletedCollections") }
    }
    /// Libraries and collections left out of the tab bar. Kept apart from
    /// them so their saved form stays the same. Home always shows.
    var hiddenTabs: Set<UUID> {
        didSet { defaults.set(hiddenTabs.map(\.uuidString), forKey: "hiddenTabs") }
    }
    /// The order of the tabs after Home, as arranged on this phone. See `tabs`.
    private(set) var tabOrder: [UUID] {
        didSet { defaults.set(tabOrder.map(\.uuidString), forKey: "tabOrder") }
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
        // The starting libraries are saved at once too: their IDs are made
        // fresh each launch, and titles and collection filters point at them.
        let libraries: [LibraryConfig]
        if let saved = defaults.data(forKey: "libraries").flatMap({ try? JSONDecoder().decode([LibraryConfig].self, from: $0) }) {
            libraries = saved
        } else {
            libraries = LibraryConfig.defaults
            defaults.set(try? JSONEncoder().encode(libraries), forKey: "libraries")
        }
        self.libraries = libraries
        framesOnShare = defaults.object(forKey: "framesOnShare") as? Bool ?? true
        hiddenTabs = Set((defaults.stringArray(forKey: "hiddenTabs") ?? []).compactMap(UUID.init(uuidString:)))
        tabOrder = (defaults.stringArray(forKey: "tabOrder") ?? []).compactMap(UUID.init(uuidString:))
        deletedCollections = defaults.data(forKey: "deletedCollections")
            .flatMap { try? JSONDecoder().decode([UUID: Date].self, from: $0) } ?? [:]
        // A kids collection to start with. Deleting it leaves none.
        if let saved = defaults.data(forKey: "collections").flatMap({ try? JSONDecoder().decode([CollectionConfig].self, from: $0) }) {
            collections = saved
        } else {
            collections = [.kidsAndFamily(libraries: libraries, starter: true)]
        }
        migrateCollections()
        defaults.set(try? JSONEncoder().encode(collections), forKey: "collections")
    }

    /// Collections from before syncing: the starter had an ID of its own on
    /// each phone, which would make one Kids & Family per phone, and library
    /// filters named this phone's library IDs rather than their folders.
    private func migrateCollections() {
        let folders = Dictionary(libraries.map { ($0.id.uuidString, $0.path) }, uniquingKeysWith: { a, _ in a })
        var hidden = hiddenTabs
        collections = collections.map { collection in
            var collection = collection
            collection.rules.filters = collection.rules.filters.map { filter in
                guard case .libraries(let values) = filter else { return filter }
                return .libraries(Set(values.map { folders[$0] ?? $0 }))
            }
            if collection.updatedAt == CollectionConfig.longAgo, collection.name == "Kids & Family",
               collection.id != CollectionConfig.starterID, !collections.contains(where: { $0.id == CollectionConfig.starterID }) {
                if hidden.remove(collection.id) != nil { hidden.insert(CollectionConfig.starterID) }
                collection.id = CollectionConfig.starterID
            }
            return collection
        }
        if hidden != hiddenTabs { hiddenTabs = hidden }
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

    /// Every library's and collection's tab, shown or not, in the order
    /// arranged. Ones never arranged (new, or synced from another phone) go
    /// after the rest: collections, then libraries.
    var tabs: [TabItem] {
        let all = collections.map(TabItem.collection) + libraries.map(TabItem.library)
        let rank = Dictionary(tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return all.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        var ids = tabs.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        tabOrder = ids
    }

    func showsTab(_ id: UUID) -> Bool { !hiddenTabs.contains(id) }

    func setTab(_ id: UUID, shown: Bool) {
        if shown { hiddenTabs.remove(id) } else { hiddenTabs.insert(id) }
    }

    func collection(_ id: UUID) -> CollectionConfig? { collections.first { $0.id == id } }

    /// Adds or updates a collection, dating a new name or filters so the
    /// change wins on the other phones. Hand picks date themselves.
    func save(_ collection: CollectionConfig) {
        var collection = collection
        if let i = collections.firstIndex(where: { $0.id == collection.id }) {
            let old = collections[i]
            if old.name != collection.name || old.rules != collection.rules { collection.updatedAt = CollectionConfig.now }
            collections[i] = collection
        } else {
            collection.updatedAt = CollectionConfig.now
            collections.append(collection)
        }
        NotificationCenter.default.post(name: .collectionsChanged, object: nil)
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        deletedCollections[id] = CollectionConfig.now
        NotificationCenter.default.post(name: .collectionsChanged, object: nil)
    }

    /// What this install writes to the share.
    func collectionsFile(device: String) -> CollectionsFile {
        CollectionsFile(device: device, collections: collections, deleted: deletedCollections)
    }

    /// Takes the collections merged from every phone.
    func adopt(_ merged: SharedCollections.Merged) {
        if merged.collections != collections { collections = merged.collections }
        if merged.deleted != deletedCollections { deletedCollections = merged.deleted }
    }

    /// A library's folder in the share, which collection filters go by.
    func libraryFolder(for id: UUID) -> String {
        library(id)?.path ?? ""
    }

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
