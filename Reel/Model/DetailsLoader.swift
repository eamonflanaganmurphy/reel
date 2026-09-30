import Foundation
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
        guard let client = client(settings), isStale(movie.details, fetchedAt: movie.detailsFetchedAt) else { return }
        try? await fetch(movie, client: client)
        try? movie.modelContext?.save()
    }

    static func load(_ show: Show, settings: AppSettings) async {
        guard let client = client(settings), isStale(show.details, fetchedAt: show.detailsFetchedAt) else { return }
        try? await fetch(show, client: client)
        try? show.modelContext?.save()
    }

    /// Doesn't save; the caller does, once for a batch.
    static func fetch(_ movie: Video, client: TMDBClient) async throws {
        guard let id = movie.tmdbID else { return }
        let details = try await notFoundAsNil { try await client.movieDetails(id: id, region: region) }
        // A scan may have removed it, or matched it to something else, meanwhile.
        guard movie.modelContext != nil, movie.tmdbID == id else { return }
        movie.detailsJSON = details.flatMap { try? JSONEncoder().encode($0) }
        movie.detailsFetchedAt = Date()
    }

    static func fetch(_ show: Show, client: TMDBClient) async throws {
        guard let id = show.tmdbID else { return }
        let details = try await notFoundAsNil { try await client.showDetails(id: id, region: region) }
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
    private static func notFoundAsNil(_ fetch: () async throws -> TMDBDetails) async throws -> TMDBDetails? {
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
    private static var region: String { Locale.current.region?.identifier ?? "US" }
}

/// Decodes many titles' details off the main thread, for the views that
/// look through the whole library.
func decodeDetails(_ blobs: [Data?]) async -> [TMDBDetails?] {
    await Task.detached(priority: .userInitiated) { blobs.map { TMDBDetails(json: $0) } }.value
}
