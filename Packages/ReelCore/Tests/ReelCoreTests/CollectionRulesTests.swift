import XCTest
@testable import ReelCore

final class CollectionRulesTests: XCTestCase {
    private let movies = "movies"
    private let kids = "childrens-shows"

    private func title(movie: Bool = true, library: String? = nil, year: Int? = 2010, rating: String? = nil,
                       genres: [String] = [], score: Double? = nil, runtime: Int? = nil, tmdb: Bool = true) -> CollectionCandidate {
        let details = tmdb ? TMDBDetails(tagline: nil, genres: genres, runtime: runtime, rating: score, certification: rating,
                                         logoPath: nil, makers: [], network: nil, cast: [], related: []) : nil
        return CollectionCandidate(library: library ?? movies, isMovie: movie, year: year, details: details, runtimeMinutes: nil)
    }

    func testAnyFilterLetsATitleIn() {
        let rules = CollectionRules(match: .any, filters: [.ageRatings(["G", "PG"]), .genres(["Family"])])
        XCTAssertTrue(rules.matches(title(rating: "PG")))
        XCTAssertTrue(rules.matches(title(rating: "PG-13", genres: ["Family", "Comedy"])))
        XCTAssertFalse(rules.matches(title(rating: "R", genres: ["Comedy"])))
    }

    func testAllFiltersMustPass() {
        let rules = CollectionRules(match: .all, filters: [.ageRatings(["PG"]), .years(from: 2000, to: nil)])
        XCTAssertTrue(rules.matches(title(year: 2005, rating: "PG")))
        XCTAssertFalse(rules.matches(title(year: 1995, rating: "PG")))
        XCTAssertFalse(rules.matches(title(year: 2005, rating: "R")))
    }

    func testExclusionsApplyEvenWhenAnyWillDo() {
        let rules = CollectionRules(match: .any, filters: [.genres(["Animation"]), .notGenres(["Horror"])])
        XCTAssertTrue(rules.matches(title(genres: ["Animation"])))
        XCTAssertFalse(rules.matches(title(genres: ["Animation", "Horror"])))
    }

    func testOnlyExclusionsTakesEverythingElse() {
        let rules = CollectionRules(filters: [.notGenres(["Horror"])])
        XCTAssertTrue(rules.matches(title(genres: ["Comedy"])))
        XCTAssertTrue(rules.matches(title(tmdb: false)))
        XCTAssertFalse(rules.matches(title(genres: ["Horror"])))
    }

    func testNoFiltersTakesNothing() {
        XCTAssertFalse(CollectionRules().matches(title(rating: "G", genres: ["Family"])))
    }

    func testContentsLimitsToMoviesOrShows() {
        let rules = CollectionRules(contents: .movies, filters: [.genres(["Family"])])
        XCTAssertTrue(rules.matches(title(movie: true, genres: ["Family"])))
        XCTAssertFalse(rules.matches(title(movie: false, genres: ["Family"])))
    }

    func testLibraryCatchesTitlesWithoutTMDB() {
        let rules = CollectionRules(filters: [.libraries(["/" + kids + "/"]), .ageRatings(["G"])])
        XCTAssertTrue(rules.matches(title(movie: false, library: kids, tmdb: false)))
        XCTAssertFalse(rules.matches(title(library: movies, tmdb: false)))
    }

    func testRatingsCompareIgnoringCaseAndSpaces() {
        let rules = CollectionRules(filters: [.ageRatings(["tv-y7"])])
        XCTAssertTrue(rules.matches(title(rating: " TV-Y7")))
    }

    func testMissingValuesFailInclusions() {
        XCTAssertFalse(CollectionFilter.years(from: 2000, to: 2010).matches(title(year: nil)))
        XCTAssertFalse(CollectionFilter.minimumRating(7).matches(title(score: nil)))
        XCTAssertFalse(CollectionFilter.maximumRuntime(100).matches(title(runtime: nil)))
        XCTAssertTrue(CollectionFilter.minimumRating(7).matches(title(score: 7.5)))
        XCTAssertTrue(CollectionFilter.maximumRuntime(100).matches(title(runtime: 95)))
        XCTAssertTrue(CollectionFilter.years(from: nil, to: 2010).matches(title(year: 1990)))
    }

    func testFileRuntimeStandsInForTMDB() {
        let candidate = CollectionCandidate(library: movies, isMovie: true, year: nil, details: nil, runtimeMinutes: 80)
        XCTAssertTrue(CollectionFilter.maximumRuntime(90).matches(candidate))
    }

    func testRoundTripsThroughJSON() throws {
        let rules = CollectionRules.kidsAndFamily
        let decoded = try JSONDecoder().decode(CollectionRules.self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }
}
