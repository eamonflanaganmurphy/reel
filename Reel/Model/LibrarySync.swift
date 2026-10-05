import CryptoKit
import Foundation
import Observation
import ReelCore
import SwiftData

/// Scans the share into SwiftData, then fills in TMDB metadata for anything
/// new. Progress is observable so Home and Settings can show it.
@MainActor
@Observable
final class LibrarySync {
    enum State: Equatable {
        case idle
        case scanning(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date

    var isRunning: Bool { if case .scanning = state { true } else { false } }

    /// Set while the scan is reading the share itself, as opposed to TMDB,
    /// which can take minutes the first time and doesn't touch the router.
    /// Downloads only need to wait for this part.
    private(set) var isReadingShare = false

    /// Videos downloaded to this device are kept when their file goes from
    /// the share, so they can still be played. Set at launch.
    weak var downloads: DownloadCenter?

    /// Until when scans list one folder at a time, after the router failed
    /// to keep up with three.
    private static let oneAtATimeKey = "scanOneAtATimeUntil"

    /// Only folders that changed since the last scan are listed again
    /// (see `ListingCache`), unless `full`, as Scan Now in Settings is, and
    /// as one scan a week is anyway.
    func run(settings: AppSettings, context: ModelContext, full: Bool = false) async {
        guard settings.isConfigured, !isRunning else { return }
        state = .scanning("Connecting…")
        isReadingShare = true
        defer { isReadingShare = false }
        await settings.tidyAddress()
        var problems: [String] = []
        let downloaded = downloads?.finishedPaths ?? []
        do {
            let config = settings.shareConfig
            let source = try ServerConnection.shared.source(for: config)
            // Folders are listed three at a time, each over a connection of
            // its own for SMB, which only does one request at a time. If the
            // router balks at the extra ones they're dropped mid-scan (see
            // `SourcePool`), and scans go one at a time for a week after.
            let oneAtATime = (UserDefaults.standard.object(forKey: Self.oneAtATimeKey) as? Date ?? .distantPast) > Date()
            let extra = config.kind == .smb && !oneAtATime ? (0..<2).compactMap { _ in try? config.makeSource() } : []
            let pool = SourcePool(([source] + (extra.isEmpty && !oneAtATime ? [source, source] : extra)).map { $0 as any FileSource })
            defer {
                for connection in extra { Task { await connection.disconnect() } }
                Task {
                    if await pool.retired > 0 {
                        UserDefaults.standard.set(Date().addingTimeInterval(7 * 24 * 60 * 60), forKey: Self.oneAtATimeKey)
                    }
                }
            }
            let lastFull = UserDefaults.standard.object(forKey: "lastFullScan") as? Date ?? .distantPast
            let full = full || Date().timeIntervalSince(lastFull) > 7 * 24 * 60 * 60
            let cache = ListingCache(base: pool, previous: full ? [:] : ScanCache.load(for: config))
            let scanner = LibraryScanner(source: cache, concurrency: oneAtATime ? 1 : 3)

            for library in settings.libraries {
                state = .scanning("Scanning \(library.name)…")
                let result: ScanResult
                do {
                    result = try await scanner.scan(root: library.path, kind: library.kind)
                } catch let error as ShareError {
                    // A wrong folder spoils one library, not the rest. Losing
                    // the server or the share still stops everything.
                    guard case .folder = error else { throw error }
                    problems.append("\(library.name): \(error.localizedDescription) Pick the folder in Settings → Libraries.")
                    continue
                }
                let existing = count(in: library, context: context)
                if result.movies.isEmpty, result.shows.isEmpty, existing > 0 {
                    // An empty folder where there used to be a library is far
                    // more likely an unmounted disk than a deleted library.
                    problems.append("\(library.name): the folder is empty, so it was left as it was.")
                    continue
                }
                switch library.kind {
                case .movies: applyMovies(result.movies, library: library, keeping: downloaded, context: context)
                case .shows: applyShows(result.shows, library: library, keeping: downloaded, context: context)
                }
                try context.save()
            }
            removeDeletedLibraries(keeping: Set(settings.libraries.map(\.id)), downloaded: downloaded, context: context)
            try context.save()
            isReadingShare = false
            for connection in extra { Task { await connection.disconnect() } }
            ScanCache.save(cache.folders, for: config)
            if full { UserDefaults.standard.set(Date(), forKey: "lastFullScan") }

            // With no internet (the router's own WiFi on a plane, or a
            // plane's WiFi wanting a sign-in) TMDB is skipped after a quick
            // check rather than a request timing out. The share scanned fine,
            // so this still counts as a sync (or every return to the app
            // would rescan the router); what's left is looked up next time
            // there's a connection.
            let key = settings.tmdbKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                state = .scanning("Checking for internet…")
            }
            if !key.isEmpty, await InternetCheck.shared.isOnline() {
                do {
                    let client = TMDBClient(apiKey: key)
                    try await fetchMetadata(client: client, settings: settings, context: context)
                    try await fetchDetails(client: client, context: context)
                    await saveArtwork(context: context)
                } catch let error as URLError {
                    await InternetCheck.shared.noteFailure(error)
                    try? context.save()
                }
            }

            // Other phones may have added frames since this one last looked.
            await SharedFrameStore.shared.refresh()
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
            state = problems.isEmpty ? .idle : .failed(problems.joined(separator: "\n"))
        } catch {
            try? context.save()
            var message = Self.describe(error)
            if let share = error as? ShareError, case .server = share, downloads?.finishedPaths.isEmpty == false {
                message += " Downloaded videos still play."
            }
            state = .failed(message)
        }
    }

    /// Forget fetched metadata so the next sync looks everything up again.
    func resetMetadata(context: ModelContext) {
        for video in (try? context.fetch(FetchDescriptor<Video>())) ?? [] { video.metadataFetched = false }
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] { show.metadataFetched = false }
        try? context.save()
    }

    /// Forget fetched metadata only for what TMDB didn't match, or matched
    /// without a poster, backdrop or description, so the next sync looks
    /// just those up again. Everything complete keeps what it has.
    func resetMissingMetadata(settings: AppSettings, context: ModelContext) {
        let tmdbLibraries = Set(settings.libraries.filter(\.useTMDB).map(\.id))
        for video in (try? context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.isMovie }))) ?? []
        where tmdbLibraries.contains(video.libraryID) {
            if video.tmdbID == nil || !Self.isTMDB(video.posterRef) || video.backdropRef == nil || video.overview.isBlank {
                video.metadataFetched = false
            }
        }
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] where tmdbLibraries.contains(show.libraryID) {
            if show.tmdbID == nil || !Self.isTMDB(show.posterRef) || show.backdropRef == nil || show.overview.isBlank {
                show.metadataFetched = false
            }
            // Specials and odd numbering often have no TMDB entry at all, so
            // only episodes TMDB could know about: ones with a number.
            for episode in show.episodes where episode.episode != nil && episode.overview.isBlank {
                episode.metadataFetched = false
            }
        }
        try? context.save()
    }

    private static func isTMDB(_ ref: String?) -> Bool { ref?.hasPrefix("https:") == true }

    private func count(in library: LibraryConfig, context: ModelContext) -> Int {
        let id = library.id
        return (try? context.fetchCount(FetchDescriptor<Video>(predicate: #Predicate { $0.libraryID == id }))) ?? 0
    }

    // MARK: Applying a scan

    private func applyMovies(_ movies: [ScannedMovie], library: LibraryConfig, keeping downloaded: Set<String>,
                             context: ModelContext) {
        let id = library.id
        let existing = (try? context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.libraryID == id }))) ?? []
        var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        for movie in movies {
            let video: Video
            if let found = byPath.removeValue(forKey: movie.video.path) {
                video = found
            } else {
                video = Video(path: movie.video.path, libraryID: id, isMovie: true, title: movie.title,
                              addedAt: movie.video.modified ?? .now)
                context.insert(video)
            }
            if !video.metadataFetched {
                video.title = movie.title
                video.year = movie.year
            }
            if video.posterRef == nil, let poster = movie.posterPath { video.posterRef = "smb:" + poster }
            apply(movie.video, to: video)
        }
        // Whatever is left was deleted from the share.
        for gone in byPath.values where !downloaded.contains(gone.path) { context.delete(gone) }
    }

    private func applyShows(_ shows: [ScannedShow], library: LibraryConfig, keeping downloaded: Set<String>,
                            context: ModelContext) {
        let id = library.id
        let existing = (try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.libraryID == id }))) ?? []
        var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        for scanned in shows {
            let firstAdded = scanned.episodes.compactMap(\.video.modified).min() ?? .now
            let show: Show
            if let found = byPath.removeValue(forKey: scanned.path) {
                show = found
            } else {
                show = Show(path: scanned.path, libraryID: id, title: scanned.title, addedAt: firstAdded)
                context.insert(show)
            }
            show.title = scanned.title
            show.year = scanned.year
            show.country = scanned.country
            show.updatedAt = scanned.episodes.compactMap(\.video.modified).max() ?? show.updatedAt
            if let poster = scanned.posterPath, show.posterRef == nil || !library.useTMDB {
                show.posterRef = "smb:" + poster
            }

            var episodesByPath = Dictionary(show.episodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for ep in scanned.episodes {
                let video: Video
                if let found = episodesByPath.removeValue(forKey: ep.video.path) {
                    video = found
                } else {
                    video = Video(path: ep.video.path, libraryID: id, isMovie: false,
                                  title: ep.title ?? "Episode \(ep.episode ?? 0)", addedAt: ep.video.modified ?? .now)
                    context.insert(video)
                    video.show = show
                }
                video.season = ep.season
                video.episode = ep.episode
                video.episodeEnd = ep.episodeEnd
                if !video.metadataFetched {
                    video.title = ep.title ?? ep.episode.map { "Episode \($0)" } ?? video.fileName
                }
                if let thumb = ep.video.thumbnailPath { video.posterRef = "smb:" + thumb }
                apply(ep.video, to: video)
            }
            for gone in episodesByPath.values where !downloaded.contains(gone.path) { context.delete(gone) }

            // YouTube channels have no poster; the first thumbnail stands in.
            if show.posterRef == nil, !library.useTMDB {
                show.posterRef = scanned.episodes.lazy.compactMap(\.video.thumbnailPath).first.map { "smb:" + $0 }
            }
        }
        for gone in byPath.values { delete(gone, keeping: downloaded, context: context) }
    }

    /// Deletes a show that's gone from the share, unless episodes of it are
    /// downloaded: then it stays with just those.
    private func delete(_ show: Show, keeping downloaded: Set<String>, context: ModelContext) {
        let kept = show.episodes.filter { downloaded.contains($0.path) }
        if kept.isEmpty {
            context.delete(show)
        } else {
            for episode in show.episodes where !downloaded.contains(episode.path) { context.delete(episode) }
        }
    }

    private func apply(_ scanned: ScannedVideo, to video: Video) {
        video.fileSize = scanned.size
        if video.subtitles != scanned.subtitles { video.subtitles = scanned.subtitles }
    }

    private func removeDeletedLibraries(keeping ids: Set<UUID>, downloaded: Set<String>, context: ModelContext) {
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] where !ids.contains(show.libraryID) {
            delete(show, keeping: downloaded, context: context)
        }
        for video in (try? context.fetch(FetchDescriptor<Video>())) ?? []
        where !ids.contains(video.libraryID) && video.show == nil && !downloaded.contains(video.path) {
            context.delete(video)
        }
    }

    // MARK: TMDB

    /// TMDB answers several requests at once about as fast as one, so
    /// lookups run a few at a time; one by one, a first scan of a big
    /// library took minutes. The answers are applied here, on the main actor.
    private func concurrently<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], _ work: @escaping @Sendable (Input) async throws -> Output,
        apply: (Output) throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Output.self) { group in
            var waiting = inputs[...]
            var running = 0
            while true {
                while running < 6, let next = waiting.popFirst() {
                    group.addTask { try await work(next) }
                    running += 1
                }
                guard let output = try await group.next() else { return }
                running -= 1
                try apply(output)
            }
        }
    }

    private func fetchMetadata(client: TMDBClient, settings: AppSettings, context: ModelContext) async throws {
        let tmdbLibraries = Set(settings.libraries.filter(\.useTMDB).map(\.id))

        let movies = try context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.isMovie && !$0.metadataFetched }))
            .filter { tmdbLibraries.contains($0.libraryID) }
        var done = 0
        let movieQueries = movies.indices.map { MovieQuery(index: $0, title: movies[$0].title, year: movies[$0].year) }
        try await concurrently(movieQueries, { query in
            MovieAnswer(index: query.index, hit: try await client.searchMovie(title: query.title, year: query.year))
        }) { answer in
            let movie = movies[answer.index]
            done += 1
            state = .scanning("Fetching movie info \(done) of \(movies.count)…")
            if let hit = answer.hit {
                if movie.tmdbID != hit.id { movie.detailsJSON = nil; movie.detailsFetchedAt = nil }
                movie.tmdbID = hit.id
                movie.title = hit.title
                movie.year = hit.year ?? movie.year
                movie.overview = hit.overview
                if let poster = TMDBClient.imageURL(hit.posterPath) { movie.posterRef = poster.absoluteString }
                movie.backdropRef = TMDBClient.imageURL(hit.backdropPath, size: "w1280")?.absoluteString
            }
            movie.metadataFetched = true
            if done % 20 == 0 { try context.save() }
        }
        try context.save()

        let shows = try context.fetch(FetchDescriptor<Show>())
            .filter { tmdbLibraries.contains($0.libraryID) && (!$0.metadataFetched || $0.episodes.contains { !$0.metadataFetched }) }
        done = 0
        let showQueries = shows.indices.map { i in
            let show = shows[i]
            return ShowQuery(index: i, search: !show.metadataFetched, title: show.title, year: show.year,
                             country: show.country, tmdbID: show.tmdbID,
                             seasons: Set(show.episodes.filter { !$0.metadataFetched }.map(\.season)).sorted())
        }
        try await concurrently(showQueries, { query in
            var hit: TMDBShow?
            var id = query.tmdbID
            if query.search {
                hit = try await client.searchShow(title: query.title, year: query.year, country: query.country)
                if let hit { id = hit.id }
            }
            // A missing season (TMDB numbers it differently) shouldn't stop
            // the rest of the library. Anything else, e.g. a network blip,
            // leaves the episodes to be looked up next time.
            var seasons: [Int: TMDBSeason] = [:]
            if let id {
                for number in query.seasons {
                    do {
                        seasons[number] = try await client.season(showID: id, number: number)
                    } catch TMDBError.http(404) {}
                }
            }
            return ShowAnswer(index: query.index, hit: hit, seasons: seasons)
        }) { answer in
            let show = shows[answer.index]
            done += 1
            state = .scanning("Fetching TV info \(done) of \(shows.count)…")
            if !show.metadataFetched {
                if let hit = answer.hit {
                    if show.tmdbID != hit.id { show.detailsJSON = nil; show.detailsFetchedAt = nil }
                    show.tmdbID = hit.id
                    show.overview = hit.overview
                    show.posterRef = TMDBClient.imageURL(hit.posterPath)?.absoluteString ?? show.posterRef
                    show.backdropRef = TMDBClient.imageURL(hit.backdropPath, size: "w1280")?.absoluteString
                }
                show.metadataFetched = true
            }
            if show.tmdbID != nil {
                for video in show.episodes where !video.metadataFetched {
                    let episodes = answer.seasons[video.season]?.episodes ?? []
                    if let n = video.episode, let ep = episodes.first(where: { $0.episodeNumber == n }) {
                        if let name = ep.name, !name.isEmpty { video.title = name }
                        video.overview = ep.overview
                        video.runtimeMinutes = ep.runtime
                        if video.posterRef == nil || video.posterRef?.hasPrefix("https") == true,
                           let still = TMDBClient.imageURL(ep.stillPath, size: "w300") {
                            video.posterRef = still.absoluteString
                        }
                    }
                    video.metadataFetched = true
                }
            } else {
                show.episodes.forEach { $0.metadataFetched = true }
            }
            if done % 10 == 0 { try context.save() }
        }
        try context.save()
    }

    /// Cast, genres and related titles for everything matched on TMDB, which
    /// the actor pages and More Like This look through. Only what's missing:
    /// a page refreshes its own when it's opened.
    private func fetchDetails(client: TMDBClient, context: ModelContext) async throws {
        let movies = try context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.isMovie && $0.tmdbID != nil }))
            .filter { DetailsLoader.isMissing($0.details, fetchedAt: $0.detailsFetchedAt) }
        let shows = try context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.tmdbID != nil }))
            .filter { DetailsLoader.isMissing($0.details, fetchedAt: $0.detailsFetchedAt) }
        let total = movies.count + shows.count
        var done = 0
        func step() throws {
            done += 1
            state = .scanning("Fetching cast and details \(done) of \(total)…")
            if done % 20 == 0 { try context.save() }
        }
        let movieIDs = movies.indices.compactMap { i in movies[i].tmdbID.map { DetailsQuery(index: i, id: $0) } }
        try await concurrently(movieIDs, { query in
            DetailsAnswer(query: query, details: try await DetailsLoader.details(movie: query.id, client: client))
        }) { answer in
            DetailsLoader.store(answer.details, in: movies[answer.query.index], id: answer.query.id)
            try step()
        }
        let showIDs = shows.indices.compactMap { i in shows[i].tmdbID.map { DetailsQuery(index: i, id: $0) } }
        try await concurrently(showIDs, { query in
            DetailsAnswer(query: query, details: try await DetailsLoader.details(show: query.id, client: client))
        }) { answer in
            DetailsLoader.store(answer.details, in: shows[answer.query.index], id: answer.query.id)
            try step()
        }
        try context.save()
    }

    /// TMDB artwork is fetched while there's internet, so the library looks
    /// complete without it. Otherwise anything not yet scrolled past falls
    /// back to frames read from the videos on the router, which then competes
    /// with whoever is watching. Posters and backdrops go first, then the
    /// title logos and cast photos the movie and show pages use. A first run
    /// is a few thousand small images, ~150 MB.
    private func saveArtwork(context: ModelContext) async {
        var art = Set<String>(), logos = Set<String>(), faces = Set<String>()
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
        for video in videos { art.formUnion([video.posterRef, video.backdropRef].compactMap { $0 }) }
        for show in shows { art.formUnion([show.posterRef, show.backdropRef].compactMap { $0 }) }
        let details = await decodeDetails(videos.filter(\.isMovie).map(\.detailsJSON) + shows.map(\.detailsJSON))
        for case let found? in details {
            if let logo = TMDBClient.imageURL(found.logoPath) { logos.insert(logo.absoluteString) }
            for person in found.cast {
                // The size the cast rows show; a person's page falls back to it.
                if let face = TMDBClient.imageURL(person.profilePath, size: "w185") { faces.insert(face.absoluteString) }
            }
        }
        let store = ArtworkStore.shared
        let wanted = { (refs: Set<String>) in refs.filter { $0.hasPrefix("https:") && !store.isSaved($0) }.sorted() }
        var queue = (wanted(art) + wanted(logos) + wanted(faces))[...]
        let total = queue.count
        guard total > 0 else { return }

        var done = 0
        var offline = false
        await withTaskGroup(of: ArtworkStore.SaveResult.self) { group in
            var running = 0
            while true {
                while running < 4, !offline, let ref = queue.popFirst() {
                    group.addTask { await store.save(ref) }
                    running += 1
                }
                guard running > 0, let result = await group.next() else { break }
                running -= 1
                done += 1
                // Lost the internet partway: the rest can wait for next time.
                if result == .offline { offline = true }
                if done % 10 == 0 || done == total {
                    state = .scanning("Saving artwork for offline use, \(done) of \(total)…")
                }
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let share = error as? ShareError, let message = share.errorDescription { return message }
        return error.localizedDescription
    }
}

private extension Optional<String> {
    var isBlank: Bool { self?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
}

// What the concurrent TMDB lookups take and give back: plain values, as the
// models stay on the main actor.
private struct MovieQuery: Sendable { let index: Int; let title: String; let year: Int? }
private struct MovieAnswer: Sendable { let index: Int; let hit: TMDBMovie? }
private struct ShowQuery: Sendable {
    let index: Int
    /// The show itself still needs matching, not just episodes.
    let search: Bool
    let title: String
    let year: Int?
    let country: String?
    let tmdbID: Int?
    /// Seasons with episodes not looked up yet.
    let seasons: [Int]
}
private struct ShowAnswer: Sendable { let index: Int; let hit: TMDBShow?; let seasons: [Int: TMDBSeason] }
private struct DetailsQuery: Sendable { let index: Int; let id: Int }
private struct DetailsAnswer: Sendable { let query: DetailsQuery; let details: TMDBDetails? }

/// Each folder's listing from the last scan, for `ListingCache`, one file per
/// share. In Caches: losing it only makes the next scan a full one.
enum ScanCache {
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScanCache", isDirectory: true)

    private static func file(for config: ShareConfig) -> URL {
        let id = "\(config.kind.rawValue)|\(config.host)|\(config.share)"
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".json")
    }

    static func load(for config: ShareConfig) -> [String: ListingCache.Folder] {
        (try? Data(contentsOf: file(for: config)))
            .flatMap { try? JSONDecoder().decode([String: ListingCache.Folder].self, from: $0) } ?? [:]
    }

    static func save(_ folders: [String: ListingCache.Folder], for config: ShareConfig) {
        let url = file(for: config)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(folders) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
