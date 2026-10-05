import XCTest
@testable import ReelCore

final class GenreBrowseTests: XCTestCase {
    private func item(movie: Bool = true, _ title: String = "", year: Int? = 2010, added: Double = 0, genres: [String] = [],
                      rating: Double? = nil, runtime: Int? = nil, makers: [String] = [], cast: [String] = [],
                      watched: Bool = false, started: Bool = false) -> BrowseItem {
        let details = TMDBDetails(tagline: nil, genres: genres, runtime: runtime, rating: rating, certification: nil, logoPath: nil,
                                  makers: makers, network: nil, cast: cast.map { TMDBCastMember(id: nil, name: $0) }, related: [])
        return BrowseItem(isMovie: movie, title: title, year: year, addedAt: Date(timeIntervalSince1970: added), details: details,
                          runtimeMinutes: nil, watched: watched, started: started)
    }

    func testTVGenresMergeWithMovieOnes() {
        XCTAssertEqual(GenreBrowse.genres(of: ["Action & Adventure", "Action", "Drama"]), ["Action", "Adventure", "Drama"])
        XCTAssertEqual(GenreBrowse.genres(of: ["Sci-Fi & Fantasy"]), ["Sci-Fi", "Fantasy"])
        XCTAssertEqual(GenreBrowse.genres(of: ["Science Fiction"]), ["Sci-Fi"])
        XCTAssertEqual(GenreBrowse.genres(of: ["War & Politics"]), ["War"])
    }

    func testMergedGenresMapBackToTMDBNames() {
        XCTAssertEqual(GenreBrowse.tmdbNames(for: "Sci-Fi"), ["Science Fiction", "Sci-Fi & Fantasy", "Sci-Fi"])
        XCTAssertEqual(GenreBrowse.tmdbNames(for: "Action"), ["Action", "Action & Adventure"])
        XCTAssertEqual(GenreBrowse.tmdbNames(for: "Comedy"), ["Comedy"])
    }

    func testLibraryRowsAreRecentThenBiggestGenres() {
        let items = [
            item("a", added: 1, genres: ["Comedy", "Drama"]),
            item("b", added: 3, genres: ["Comedy"]),
            item("c", added: 2, genres: ["Comedy", "Drama"]),
            item("d", added: 4, genres: ["Drama", "Horror"]),
        ]
        let rows = GenreBrowse.libraryRows(items, minimum: 2)
        XCTAssertEqual(rows.map(\.title), ["Recently Added", "Comedy", "Drama"])
        XCTAssertEqual(rows[0].indices, [3, 1, 2, 0])
    }

    func testGenreRowPutsUnwatchedFirstThenBestRated() {
        let items = [
            item("seen", genres: ["Comedy"], rating: 9, watched: true),
            item("ok", genres: ["Comedy"], rating: 6),
            item("great", genres: ["Comedy"], rating: 8),
        ]
        XCTAssertEqual(GenreBrowse.libraryRows(items, minimum: 1)[1].indices, [2, 1, 0])
    }

    func testCombiningGenresNeedsEveryOne() {
        let items = [item(genres: ["Comedy", "Romance"]), item(genres: ["Comedy"]), item(genres: ["Romance"])]
        XCTAssertEqual(GenreBrowse.indices(in: ["Comedy", "Romance"], of: items), [0])
    }

    func testPairingsOnlyOfferGenresThatNarrowItDown() {
        let items = [
            item(genres: ["Comedy", "Romance", "Family"]),
            item(genres: ["Comedy", "Romance"]),
            item(genres: ["Comedy", "Drama", "Family"]),
            item(genres: ["Comedy", "Drama", "Family"]),
            item(genres: ["Comedy", "Horror"]),
        ]
        XCTAssertEqual(GenreBrowse.pairings(for: ["Comedy"], in: items), ["Family", "Drama", "Romance"])
        // Every Comedy-Romance is both, and one alone isn't worth a chip.
        XCTAssertEqual(GenreBrowse.pairings(for: ["Comedy", "Romance"], in: items), [])
    }

    func testGenreRows() {
        var items: [BrowseItem] = []
        for i in 0..<5 {
            items.append(item(year: 1995, added: Double(i), genres: ["Comedy"], rating: Double(i), runtime: 90,
                              makers: ["Nora"], cast: ["Meg"], watched: i == 0))
        }
        for i in 0..<5 {
            items.append(item(year: 2015, added: Double(10 + i), genres: ["Comedy"], runtime: 120, cast: ["Meg"]))
        }
        let rows = GenreBrowse.genreRows(items, indices: Array(items.indices))
        XCTAssertEqual(rows.map(\.title), ["Haven't Watched", "Top Rated", "Recently Added", "2010s", "1990s",
                                           "Under 100 Minutes", "Directed by Nora"])
        XCTAssertEqual(rows[1].indices, [4, 3, 2, 1, 0])
        XCTAssertFalse(rows[0].indices.contains(0))
    }

    func testOneDecadeGetsNoDecadeRow() {
        let items = (0..<6).map { item(year: 2000 + $0, genres: ["Drama"]) }
        XCTAssertFalse(GenreBrowse.genreRows(items, indices: Array(items.indices)).contains { $0.title.hasSuffix("0s") })
    }

    func testShowsGetHalfHourAndCreatorRows() {
        let items = (0..<8).map { item(movie: false, genres: ["Comedy"], runtime: $0 < 5 ? 22 : 50, makers: $0 < 4 ? ["Mike"] : []) }
        let titles = GenreBrowse.genreRows(items, indices: Array(items.indices)).map(\.title)
        XCTAssertTrue(titles.contains("Half-Hour Episodes"))
        XCTAssertTrue(titles.contains("Created by Mike"))
    }
}
