import Foundation
import ReelCore
import SwiftData

/// Cast, genres, ratings and title logos for the movie and show pages. The
/// scan doesn't need them, so they're fetched when a page first opens and
/// kept, which also has them there offline. Refetched after a month, for
/// shows that are still adding seasons and cast.
@MainActor
enum DetailsLoader {
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static func load(_ movie: Video, settings: AppSettings) async {
        guard let id = movie.tmdbID, isStale(movie.detailsFetchedAt), let client = client(settings),
              let details = try? await client.movieDetails(id: id, region: region),
              // A scan may have removed it, or matched it to something else, meanwhile.
              movie.modelContext != nil, movie.tmdbID == id else { return }
        movie.detailsJSON = try? JSONEncoder().encode(details)
        movie.detailsFetchedAt = Date()
        try? movie.modelContext?.save()
    }

    static func load(_ show: Show, settings: AppSettings) async {
        guard let id = show.tmdbID, isStale(show.detailsFetchedAt), let client = client(settings),
              let details = try? await client.showDetails(id: id, region: region),
              show.modelContext != nil, show.tmdbID == id else { return }
        show.detailsJSON = try? JSONEncoder().encode(details)
        show.detailsFetchedAt = Date()
        try? show.modelContext?.save()
    }

    private static func client(_ settings: AppSettings) -> TMDBClient? {
        settings.tmdbKey.isEmpty ? nil : TMDBClient(apiKey: settings.tmdbKey)
    }

    /// For the age rating, e.g. Danish ones in Denmark.
    private static var region: String { Locale.current.region?.identifier ?? "US" }

    private static func isStale(_ fetched: Date?) -> Bool {
        fetched.map { Date().timeIntervalSince($0) > maxAge } ?? true
    }
}
