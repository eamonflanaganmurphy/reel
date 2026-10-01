import Foundation

/// One test a title has to pass to join a collection on its own. Each takes
/// several values, any of which will do: rated G *or* PG, in the Family *or*
/// Animation genre.
public enum CollectionFilter: Codable, Sendable, Hashable {
    /// In one of these libraries.
    case libraries(Set<UUID>)
    /// TMDB's age rating is one of these, e.g. "G", "PG", "TV-Y".
    case ageRatings(Set<String>)
    /// In at least one of these genres.
    case genres(Set<String>)
    /// In none of these genres. Always applies, however the others combine.
    case notGenres(Set<String>)
    /// Released in this range, either end open.
    case years(from: Int?, to: Int?)
    /// TMDB rating, out of 10, at least this.
    case minimumRating(Double)
    /// No longer than this many minutes: the movie, or a typical episode.
    case maximumRuntime(Int)

    /// Whether it keeps titles out rather than letting them in.
    public var isExclusion: Bool {
        if case .notGenres = self { return true }
        return false
    }

    /// A title with nothing to go on, e.g. no age rating, fails an inclusion
    /// and passes an exclusion.
    public func matches(_ title: CollectionCandidate) -> Bool {
        switch self {
        case .libraries(let ids):
            return ids.contains(title.libraryID)
        case .ageRatings(let ratings):
            guard let rating = title.details?.certification.map(Self.normalized) else { return false }
            return ratings.contains { Self.normalized($0) == rating }
        case .genres(let genres):
            return !genres.isDisjoint(with: title.details?.genres ?? [])
        case .notGenres(let genres):
            return genres.isDisjoint(with: title.details?.genres ?? [])
        case .years(let from, let to):
            guard let year = title.year else { return false }
            return year >= (from ?? .min) && year <= (to ?? .max)
        case .minimumRating(let minimum):
            guard let rating = title.details?.rating else { return false }
            return rating >= minimum
        case .maximumRuntime(let minutes):
            guard let runtime = title.runtimeMinutes else { return false }
            return runtime <= minutes
        }
    }

    /// "pg" and " PG " are the same rating.
    static func normalized(_ rating: String) -> String {
        rating.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

/// What a filter can look at in a movie or show.
public struct CollectionCandidate: Sendable {
    public var libraryID: UUID
    public var isMovie: Bool
    public var year: Int?
    public var details: TMDBDetails?
    /// TMDB's runtime, a typical episode's for a show, else the file's own length.
    public var runtimeMinutes: Int?

    public init(libraryID: UUID, isMovie: Bool, year: Int?, details: TMDBDetails?, runtimeMinutes: Int?) {
        self.libraryID = libraryID
        self.isMovie = isMovie
        self.year = year
        self.details = details
        self.runtimeMinutes = details?.runtime ?? runtimeMinutes
    }
}

/// Which titles a collection takes in by itself, from what TMDB says about
/// them. Titles added or removed by hand are kept by the collection itself,
/// on top of this.
public struct CollectionRules: Codable, Sendable, Hashable {
    public enum Contents: String, Codable, Sendable, CaseIterable {
        case movies, shows, both
    }

    /// How the filters that let titles in combine. Exclusions always apply.
    public enum Match: String, Codable, Sendable, CaseIterable {
        case all, any
    }

    public var contents: Contents
    public var match: Match
    public var filters: [CollectionFilter]

    public init(contents: Contents = .both, match: Match = .any, filters: [CollectionFilter] = []) {
        self.contents = contents
        self.match = match
        self.filters = filters
    }

    /// No filters means nothing joins by itself: a collection picked by
    /// hand. Only exclusions means everything not excluded.
    public func matches(_ title: CollectionCandidate) -> Bool {
        guard !filters.isEmpty else { return false }
        switch contents {
        case .movies: guard title.isMovie else { return false }
        case .shows: guard !title.isMovie else { return false }
        case .both: break
        }
        let inclusions = filters.filter { !$0.isExclusion }
        let exclusions = filters.filter(\.isExclusion)
        guard exclusions.allSatisfy({ $0.matches(title) }) else { return false }
        guard !inclusions.isEmpty else { return true }
        switch match {
        case .all: return inclusions.allSatisfy { $0.matches(title) }
        case .any: return inclusions.contains { $0.matches(title) }
        }
    }

    /// A starting point for a kids' collection: rated for young children, or
    /// family or animation, and nothing scary.
    public static let kidsAndFamily = CollectionRules(contents: .both, match: .any, filters: [
        .ageRatings(["G", "PG", "U", "TV-Y", "TV-Y7", "TV-G"]),
        .genres(["Family", "Animation", "Kids"]),
        .notGenres(["Horror", "Thriller", "Crime", "War"]),
    ])
}
