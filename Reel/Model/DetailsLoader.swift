import Foundation
import Network
import ReelCore
import SwiftData

/// Cast, genres, ratings, related titles and title logos. The scan fetches
/// them for everything matched on TMDB, since the actor pages and More Like
/// This look across the whole library; a page refetches its own when it's
/// opened and they're a month old, for shows still adding seasons and cast.
@MainActor
enum DetailsLoader {
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static func load(_ movie: Video, settings: AppSettings) async {
        guard let client = client(settings), isStale(movie.details, fetchedAt: movie.detailsFetchedAt),
              let id = movie.tmdbID, await InternetCheck.shared.isOnline() else { return }
        do {
            store(try await details(movie: id, client: client), in: movie, id: id)
            try? movie.modelContext?.save()
        } catch {
            await InternetCheck.shared.noteFailure(error)
        }
    }

    static func load(_ show: Show, settings: AppSettings) async {
        guard let client = client(settings), isStale(show.details, fetchedAt: show.detailsFetchedAt),
              let id = show.tmdbID, await InternetCheck.shared.isOnline() else { return }
        do {
            store(try await details(show: id, client: client), in: show, id: id)
            try? show.modelContext?.save()
        } catch {
            await InternetCheck.shared.noteFailure(error)
        }
    }

    /// From TMDB, off the main actor, so a scan can have several on the way.
    nonisolated static func details(movie id: Int, client: TMDBClient) async throws -> TMDBDetails? {
        try await notFoundAsNil { try await client.movieDetails(id: id, region: region) }
    }

    nonisolated static func details(show id: Int, client: TMDBClient) async throws -> TMDBDetails? {
        try await notFoundAsNil { try await client.showDetails(id: id, region: region) }
    }

    /// Keeps details fetched for the TMDB title `id`. Doesn't save; the
    /// caller does, once for a batch.
    static func store(_ details: TMDBDetails?, in movie: Video, id: Int) {
        // A scan may have removed it, or matched it to something else, meanwhile.
        guard movie.modelContext != nil, movie.tmdbID == id else { return }
        movie.detailsJSON = details.flatMap { try? JSONEncoder().encode($0) }
        movie.detailsFetchedAt = Date()
    }

    static func store(_ details: TMDBDetails?, in show: Show, id: Int) {
        guard show.modelContext != nil, show.tmdbID == id else { return }
        show.detailsJSON = details.flatMap { try? JSONEncoder().encode($0) }
        show.detailsFetchedAt = Date()
    }

    /// Never fetched, or fetched before a field was added.
    static func isMissing(_ details: TMDBDetails?, fetchedAt: Date?) -> Bool {
        guard fetchedAt != nil else { return true }
        return (details?.schema ?? TMDBDetails.currentSchema) < TMDBDetails.currentSchema
    }

    private static func isStale(_ details: TMDBDetails?, fetchedAt: Date?) -> Bool {
        isMissing(details, fetchedAt: fetchedAt) || fetchedAt.map { Date().timeIntervalSince($0) > maxAge } ?? true
    }

    /// A title TMDB has since removed is fetched as having no details,
    /// rather than tried again on every scan.
    nonisolated private static func notFoundAsNil(_ fetch: () async throws -> TMDBDetails) async throws -> TMDBDetails? {
        do {
            return try await fetch()
        } catch TMDBError.http(404) {
            return nil
        }
    }

    private static func client(_ settings: AppSettings) -> TMDBClient? {
        let key = settings.tmdbKey.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : TMDBClient(apiKey: key)
    }

    /// For the age rating, e.g. Danish ones in Denmark.
    nonisolated private static var region: String { Locale.current.region?.identifier ?? "US" }
}

/// Whether TMDB can be reached, found out in a few seconds, so nothing waits
/// out a request's timeout with no internet: on the router's own WiFi on a
/// plane, its DNS can take ages to give up on every lookup. The answer is
/// kept for a while, and forgotten when the phone changes network.
actor InternetCheck {
    static let shared = InternetCheck()

    private var known: (online: Bool, at: Date)?
    private var probe: Task<Bool, Never>?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { _ in
            Task { await InternetCheck.shared.forget() }
        }
        monitor.start(queue: DispatchQueue(label: "InternetCheck"))
    }

    func isOnline() async -> Bool {
        if let known, Date().timeIntervalSince(known.at) < (known.online ? 600 : 60) { return known.online }
        // Everything that asks at once waits on the one check.
        let task = probe ?? Task { await Self.reachesTMDB() }
        probe = task
        let online = await task.value
        if probe == task {
            probe = nil
            known = (online, .now)
        }
        return online
    }

    /// A request failed for want of internet after all, e.g. the router
    /// lost its own connection: nothing else tries for a minute.
    func noteFailure(_ error: Error) {
        if let error = error as? URLError, ArtworkStore.isOffline(error) { known = (false, .now) }
    }

    private func forget() {
        known = nil
    }

    /// Any answer at all from TMDB's API (even the 401 for no key) means
    /// it's reachable. A WiFi wanting a sign-in fails on its certificate.
    private static func reachesTMDB() async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.themoviedb.org/3/configuration")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}

/// Decodes many titles' details off the main thread, for the views that
/// look through the whole library.
func decodeDetails(_ blobs: [Data?]) async -> [TMDBDetails?] {
    await Task.detached(priority: .userInitiated) { blobs.map { TMDBDetails(json: $0) } }.value
}
