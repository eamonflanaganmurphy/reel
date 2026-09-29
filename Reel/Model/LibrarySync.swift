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

    func run(settings: AppSettings, context: ModelContext) async {
        guard settings.isConfigured, !isRunning else { return }
        state = .scanning("Connecting…")
        await settings.tidyAddress()
        var problems: [String] = []
        do {
            let config = settings.smbConfig
            let source = try ServerConnection.shared.source(for: config)
            let scanner = LibraryScanner(source: source)

            for library in settings.libraries {
                state = .scanning("Scanning \(library.name)…")
                let result: ScanResult
                do {
                    result = try await scanner.scan(root: library.path, kind: library.kind)
                } catch let error as SMBError {
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
                case .movies: applyMovies(result.movies, library: library, context: context)
                case .shows: applyShows(result.shows, library: library, context: context)
                }
                try context.save()
            }
            removeDeletedLibraries(keeping: Set(settings.libraries.map(\.id)), context: context)
            try context.save()

            let key = settings.tmdbKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                do {
                    try await fetchMetadata(client: TMDBClient(apiKey: key), settings: settings, context: context)
                    await saveArtwork(context: context)
                } catch let error as URLError where ArtworkStore.isOffline(error) {
                    // No internet, e.g. on the router's own WiFi on a plane.
                    // The share scanned fine, so this still counts as a sync
                    // (or every return to the app would rescan the router);
                    // what's left is looked up next time there's a connection.
                    try? context.save()
                }
            }

            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
            state = problems.isEmpty ? .idle : .failed(problems.joined(separator: "\n"))
        } catch {
            try? context.save()
            state = .failed(Self.describe(error))
        }
    }

    /// Forget fetched metadata so the next sync looks everything up again.
    func resetMetadata(context: ModelContext) {
        for video in (try? context.fetch(FetchDescriptor<Video>())) ?? [] { video.metadataFetched = false }
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] { show.metadataFetched = false }
        try? context.save()
    }

    private func count(in library: LibraryConfig, context: ModelContext) -> Int {
        let id = library.id
        return (try? context.fetchCount(FetchDescriptor<Video>(predicate: #Predicate { $0.libraryID == id }))) ?? 0
    }

    // MARK: Applying a scan

    private func applyMovies(_ movies: [ScannedMovie], library: LibraryConfig, context: ModelContext) {
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
        for gone in byPath.values { context.delete(gone) }
    }

    private func applyShows(_ shows: [ScannedShow], library: LibraryConfig, context: ModelContext) {
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
            for gone in episodesByPath.values { context.delete(gone) }

            // YouTube channels have no poster; the first thumbnail stands in.
            if show.posterRef == nil, !library.useTMDB {
                show.posterRef = scanned.episodes.lazy.compactMap(\.video.thumbnailPath).first.map { "smb:" + $0 }
            }
        }
        for gone in byPath.values { context.delete(gone) }
    }

    private func apply(_ scanned: ScannedVideo, to video: Video) {
        video.fileSize = scanned.size
        if video.subtitles != scanned.subtitles { video.subtitles = scanned.subtitles }
    }

    private func removeDeletedLibraries(keeping ids: Set<UUID>, context: ModelContext) {
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] where !ids.contains(show.libraryID) {
            context.delete(show)
        }
        for video in (try? context.fetch(FetchDescriptor<Video>())) ?? [] where !ids.contains(video.libraryID) && video.show == nil {
            context.delete(video)
        }
    }

    // MARK: TMDB

    private func fetchMetadata(client: TMDBClient, settings: AppSettings, context: ModelContext) async throws {
        let tmdbLibraries = Set(settings.libraries.filter(\.useTMDB).map(\.id))

        let movies = try context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.isMovie && !$0.metadataFetched }))
            .filter { tmdbLibraries.contains($0.libraryID) }
        for (i, movie) in movies.enumerated() {
            state = .scanning("Fetching movie info \(i + 1) of \(movies.count)…")
            if let hit = try await client.searchMovie(title: movie.title, year: movie.year) {
                movie.tmdbID = hit.id
                movie.title = hit.title
                movie.year = hit.year ?? movie.year
                movie.overview = hit.overview
                if let poster = TMDBClient.imageURL(hit.posterPath) { movie.posterRef = poster.absoluteString }
                movie.backdropRef = TMDBClient.imageURL(hit.backdropPath, size: "w1280")?.absoluteString
            }
            movie.metadataFetched = true
            if i % 20 == 19 { try context.save() }
        }
        try context.save()

        let shows = try context.fetch(FetchDescriptor<Show>())
            .filter { tmdbLibraries.contains($0.libraryID) && ($0.tmdbID == nil ? !$0.metadataFetched : $0.episodes.contains { !$0.metadataFetched }) }
        for (i, show) in shows.enumerated() {
            state = .scanning("Fetching TV info \(i + 1) of \(shows.count)…")
            if !show.metadataFetched {
                if let hit = try await client.searchShow(title: show.title, year: show.year, country: show.country) {
                    show.tmdbID = hit.id
                    show.overview = hit.overview
                    show.posterRef = TMDBClient.imageURL(hit.posterPath)?.absoluteString ?? show.posterRef
                    show.backdropRef = TMDBClient.imageURL(hit.backdropPath, size: "w1280")?.absoluteString
                }
                show.metadataFetched = true
            }
            guard let tmdbID = show.tmdbID else {
                show.episodes.forEach { $0.metadataFetched = true }
                continue
            }
            let pending = show.episodes.filter { !$0.metadataFetched }
            for season in Set(pending.map(\.season)).sorted() {
                // A missing season (TMDB numbers it differently) shouldn't
                // stop the rest of the library. Anything else, e.g. a network
                // blip, leaves the episodes to be looked up next time.
                let details: TMDBSeason?
                do {
                    details = try await client.season(showID: tmdbID, number: season)
                } catch TMDBError.http(404) {
                    details = nil
                }
                let byNumber = Dictionary((details?.episodes ?? []).map { ($0.episodeNumber, $0) }, uniquingKeysWith: { a, _ in a })
                for video in pending where video.season == season {
                    if let n = video.episode, let ep = byNumber[n] {
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
            }
            try context.save()
        }
    }

    /// TMDB artwork is fetched while there's internet, so the library looks
    /// complete without it. Otherwise anything not yet scrolled past falls
    /// back to frames read from the videos on the router, which then competes
    /// with whoever is watching. A first run is ~1,700 images, ~100 MB.
    private func saveArtwork(context: ModelContext) async {
        var refs = Set<String>()
        for video in (try? context.fetch(FetchDescriptor<Video>())) ?? [] {
            refs.formUnion([video.posterRef, video.backdropRef].compactMap { $0 })
        }
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] {
            refs.formUnion([show.posterRef, show.backdropRef].compactMap { $0 })
        }
        let store = ArtworkStore.shared
        var queue = refs.filter { $0.hasPrefix("https:") && !store.isSaved($0) }.sorted()[...]
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
        if let smb = error as? SMBError, let message = smb.errorDescription { return message }
        return error.localizedDescription
    }
}
