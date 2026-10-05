import Foundation

/// What browsing by genre looks at in a movie or show.
public struct BrowseItem: Sendable {
    public var isMovie: Bool
    public var title: String
    public var year: Int?
    public var addedAt: Date
    /// Merged across movies and TV; see `GenreBrowse.genres(of:)`.
    public var genres: [String]
    public var rating: Double?
    /// The movie's, or a typical episode's.
    public var runtimeMinutes: Int?
    /// Directors of a movie, creators of a show.
    public var makers: [String]
    /// The top-billed few.
    public var cast: [String]
    /// The movie, or every episode of the show.
    public var watched: Bool
    /// Any of it watched or under way.
    public var started: Bool

    public init(isMovie: Bool, title: String, year: Int?, addedAt: Date, details: TMDBDetails?, runtimeMinutes: Int?,
                watched: Bool, started: Bool) {
        self.isMovie = isMovie
        self.title = title
        self.year = year
        self.addedAt = addedAt
        genres = GenreBrowse.genres(of: details?.genres ?? [])
        rating = details?.rating
        self.runtimeMinutes = details?.runtime ?? runtimeMinutes
        makers = details?.makers ?? []
        cast = (details?.cast ?? []).prefix(GenreBrowse.billedCast).map(\.name)
        self.watched = watched
        self.started = started
    }
}

/// A titled row of titles, as indices into the items it was made from.
public struct BrowseShelf: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case recentlyAdded, unwatched, topRated, short
        case decade(Int)
        case genre(String)
        case maker(String)
        case actor(String)
    }

    public var kind: Kind
    public var title: String
    public var indices: [Int]

    public var id: Kind { kind }
}

/// Rows for browsing a library by genre, and for one genre's own page.
public enum GenreBrowse {
    /// How many of a title's cast count towards "Starring" rows.
    static let billedCast = 5
    /// Titles in a row.
    public static let rowLength = 20
    /// Below this many titles, rows would mostly repeat each other, so a
    /// page shows them all in one grid instead.
    public static let minimumForRows = 12
    /// Titles a genre needs for its own row on a library's page.
    public static let minimumForGenreRow = 3

    /// TMDB names some genres differently for TV ("Sci-Fi & Fantasy") than
    /// for movies ("Science Fiction", "Fantasy"). These are split or renamed
    /// so a movie and a show in the same genre land in the same row.
    static let merged: [String: [String]] = [
        "Action & Adventure": ["Action", "Adventure"],
        "Sci-Fi & Fantasy": ["Sci-Fi", "Fantasy"],
        "Science Fiction": ["Sci-Fi"],
        "War & Politics": ["War"],
    ]

    /// A title's genres as the app shows them, in TMDB's order, without repeats.
    public static func genres(of tmdbGenres: [String]) -> [String] {
        var seen = Set<String>()
        return tmdbGenres.flatMap { merged[$0] ?? [$0] }.filter { seen.insert($0).inserted }
    }

    /// The TMDB genres that make up one of ours, for a collection's filters,
    /// which go by TMDB's names.
    public static func tmdbNames(for genre: String) -> Set<String> {
        Set(merged.filter { $0.value.contains(genre) }.map(\.key)).union(merged[genre] == nil ? [genre] : [])
    }

    public struct Count: Sendable, Hashable, Identifiable {
        public var genre: String
        public var count: Int
        public var id: String { genre }
    }

    /// Every genre among the items, most titles first.
    public static func counts(_ items: [BrowseItem], in indices: [Int]? = nil) -> [Count] {
        var counts: [String: Int] = [:]
        for i in indices ?? Array(items.indices) {
            for genre in items[i].genres { counts[genre, default: 0] += 1 }
        }
        return counts.map { Count(genre: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.genre) > ($1.count, $0.genre) }
    }

    /// The items in every one of `genres`.
    public static func indices(in genres: [String], of items: [BrowseItem]) -> [Int] {
        items.indices.filter { i in genres.allSatisfy(items[i].genres.contains) }
    }

    /// A library's front page: Recently Added, then a row for each genre
    /// with at least `minimum` titles, biggest first. Each genre's row puts
    /// what hasn't been watched first, best rated first.
    public static func libraryRows(_ items: [BrowseItem], minimum: Int = minimumForGenreRow) -> [BrowseShelf] {
        var rows: [BrowseShelf] = []
        let recent = items.indices.sorted { items[$0].addedAt > items[$1].addedAt }
        if !recent.isEmpty {
            rows.append(BrowseShelf(kind: .recentlyAdded, title: "Recently Added", indices: Array(recent.prefix(rowLength))))
        }
        for genre in counts(items) where genre.count >= minimum {
            let ranked = byInterest(indices(in: [genre.genre], of: items), items)
            rows.append(BrowseShelf(kind: .genre(genre.genre), title: genre.genre, indices: Array(ranked.prefix(rowLength))))
        }
        return rows
    }

    /// The rows on a genre's own page, for the titles in `indices`: what
    /// hasn't been watched, the best rated, the newest, each decade, the
    /// short ones, and the directors and actors it has most of. Rows with
    /// too few titles to be worth a row are left out.
    public static func genreRows(_ items: [BrowseItem], indices: [Int]) -> [BrowseShelf] {
        let minimum = 4
        var rows: [BrowseShelf] = []
        func add(_ kind: BrowseShelf.Kind, _ title: String, _ picked: [Int]) {
            guard picked.count >= minimum else { return }
            rows.append(BrowseShelf(kind: kind, title: title, indices: Array(picked.prefix(rowLength))))
        }

        add(.unwatched, "Haven't Watched", byRating(indices.filter { !items[$0].started && !items[$0].watched }, items))
        add(.topRated, "Top Rated", byRating(indices.filter { items[$0].rating != nil }, items))
        add(.recentlyAdded, "Recently Added", indices.sorted { items[$0].addedAt > items[$1].addedAt })

        // One per decade, newest first, but only when there are two: a
        // single decade's row would just be everything again.
        let decades = Dictionary(grouping: indices.filter { items[$0].year != nil }) { items[$0].year! / 10 * 10 }
            .filter { $0.value.count >= minimum }
        if decades.count > 1 {
            for decade in decades.keys.sorted(by: >) {
                add(.decade(decade), "\(decade)s", byRating(decades[decade]!, items))
            }
        }

        let movies = indices.filter { items[$0].isMovie }
        let shows = indices.filter { !items[$0].isMovie }
        let short = movies.filter { items[$0].runtimeMinutes.map { $0 < 100 } ?? false }
            + shows.filter { items[$0].runtimeMinutes.map { $0 <= 35 } ?? false }
        let shortTitle = shows.isEmpty ? "Under 100 Minutes" : movies.isEmpty ? "Half-Hour Episodes" : "Short Ones"
        if short.count < indices.count { add(.short, shortTitle, byRating(short, items)) }

        for (name, picked) in mostFrequent(indices, items, minimum: 3, keyPath: \.makers) {
            let title = picked.allSatisfy { items[$0].isMovie } ? "Directed by \(name)"
                : picked.allSatisfy { !items[$0].isMovie } ? "Created by \(name)" : "From \(name)"
            rows.append(BrowseShelf(kind: .maker(name), title: title, indices: Array(byRating(picked, items).prefix(rowLength))))
        }
        for (name, picked) in mostFrequent(indices, items, minimum: 3, keyPath: \.cast) {
            rows.append(BrowseShelf(kind: .actor(name), title: "Starring \(name)", indices: Array(byRating(picked, items).prefix(rowLength))))
        }
        return rows
    }

    /// Genres that narrow `selected` down further: the ones most often
    /// alongside it, leaving out any every title already has.
    public static func pairings(for selected: [String], in items: [BrowseItem], limit: Int = 12) -> [String] {
        let matching = indices(in: selected, of: items)
        return counts(items, in: matching)
            .filter { !selected.contains($0.genre) && $0.count >= 2 && $0.count < matching.count }
            .prefix(limit)
            .map { $0.genre }
    }

    /// Up to two people in the most titles, at least `minimum` and not all
    /// of them, with those titles.
    private static func mostFrequent(_ indices: [Int], _ items: [BrowseItem], minimum: Int,
                                     keyPath: KeyPath<BrowseItem, [String]>) -> [(String, [Int])] {
        var titles: [String: [Int]] = [:]
        for i in indices {
            for name in Set(items[i][keyPath: keyPath]) { titles[name, default: []].append(i) }
        }
        return titles.filter { $0.value.count >= minimum && $0.value.count < indices.count }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .prefix(2)
            .map { ($0.key, $0.value) }
    }

    /// Best rated first; unrated last, newest first.
    static func byRating(_ indices: [Int], _ items: [BrowseItem]) -> [Int] {
        indices.sorted { a, b in
            let (x, y) = (items[a], items[b])
            if (x.rating ?? -1) != (y.rating ?? -1) { return (x.rating ?? -1) > (y.rating ?? -1) }
            return x.addedAt > y.addedAt
        }
    }

    /// Not yet watched first, then best rated.
    static func byInterest(_ indices: [Int], _ items: [BrowseItem]) -> [Int] {
        let ranked = byRating(indices, items)
        return ranked.filter { !items[$0].watched } + ranked.filter { items[$0].watched }
    }
}
