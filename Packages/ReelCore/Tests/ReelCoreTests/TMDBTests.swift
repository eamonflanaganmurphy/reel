import XCTest
@testable import ReelCore

final class TMDBTests: XCTestCase {

    func testDecodeShowSearchAndPickCountry() throws {
        let json = """
        {"page":1,"results":[
          {"id":2996,"name":"The Office","first_air_date":"2001-07-09","overview":"UK","poster_path":"/uk.jpg","backdrop_path":null,"origin_country":["GB"]},
          {"id":2316,"name":"The Office","first_air_date":"2005-03-24","overview":"US","poster_path":"/us.jpg","backdrop_path":"/usb.jpg","origin_country":["US"]}
        ]}
        """
        let page = try TMDBClient.decoder.decode(TMDBPage<TMDBShow>.self, from: Data(json.utf8))
        XCTAssertEqual(TMDBClient.bestShow(page.results, country: "US")?.id, 2316)
        XCTAssertEqual(TMDBClient.bestShow(page.results, country: nil)?.id, 2996)
        XCTAssertEqual(page.results[1].year, 2005)
    }

    func testDecodeSeason() throws {
        let json = """
        {"_id":"x","air_date":"2019-01-01","season_number":2,"poster_path":"/s2.jpg","episodes":[
          {"episode_number":1,"season_number":2,"name":"Dance Mode","overview":"...","still_path":"/e1.jpg","runtime":7,"air_date":"2019-03-18"}
        ]}
        """
        let season = try TMDBClient.decoder.decode(TMDBSeason.self, from: Data(json.utf8))
        XCTAssertEqual(season.episodes.first?.name, "Dance Mode")
        XCTAssertEqual(season.episodes.first?.stillPath, "/e1.jpg")
    }

    func testDecodeMovieDetails() throws {
        let json = """
        {"id":603,"tagline":"Welcome to the Real World.","runtime":136,"vote_average":8.2,"vote_count":26000,
         "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}],
         "credits":{"cast":[{"id":6384,"name":"Keanu Reeves","character":"Neo","profile_path":"/k.jpg","order":0},
                            {"name":"Laurence Fishburne","character":"","profile_path":null,"order":1}],
                    "crew":[{"name":"Lana Wachowski","job":"Director"},{"name":"Bill Pope","job":"Director of Photography"}]},
         "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"","type":1},{"certification":"R","type":3}]},
                                     {"iso_3166_1":"DK","release_dates":[{"certification":"15","type":3}]}]},
         "images":{"logos":[{"file_path":"/logo.svg","iso_639_1":"en"},{"file_path":"/logo.png","iso_639_1":"en"}]},
         "recommendations":{"page":1,"results":[{"id":604},{"id":605}]},"similar":{"page":1,"results":[{"id":605},{"id":27205}]}}
        """
        let raw = try TMDBClient.decoder.decode(TMDBMovieDetails.self, from: Data(json.utf8))
        let details = raw.details(region: "DK")
        XCTAssertEqual(details.tagline, "Welcome to the Real World.")
        XCTAssertEqual(details.genres, ["Action", "Science Fiction"])
        XCTAssertEqual(details.runtime, 136)
        XCTAssertEqual(details.rating, 8.2)
        XCTAssertEqual(details.certification, "15")
        XCTAssertEqual(raw.details(region: "SE").certification, "R")
        XCTAssertEqual(details.logoPath, "/logo.png")
        XCTAssertEqual(details.makers, ["Lana Wachowski"])
        XCTAssertEqual(details.cast.map(\.name), ["Keanu Reeves", "Laurence Fishburne"])
        XCTAssertNil(details.cast[1].character)
        XCTAssertEqual(details.cast[0].id, 6384)
        XCTAssertEqual(details.related, [604, 605, 27205])
        XCTAssertEqual(details.schema, TMDBDetails.currentSchema)

        // Round-trips as it's stored on the model.
        let stored = try JSONDecoder().decode(TMDBDetails.self, from: JSONEncoder().encode(details))
        XCTAssertEqual(stored, details)
    }

    func testDecodeShowDetails() throws {
        let json = """
        {"id":82728,"tagline":"","episode_run_time":[],"vote_average":8.9,"vote_count":5,
         "genres":[{"id":16,"name":"Animation"}],"created_by":[{"name":"Joe Brumm"}],"networks":[{"name":"ABC Kids"}],
         "aggregate_credits":{"cast":[{"name":"David McCormack","profile_path":"/d.jpg","total_episode_count":150,
             "roles":[{"character":"Bandit (voice)","episode_count":148},{"character":"Rad (voice)","episode_count":2}]}]},
         "content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-Y"}]},
         "images":{"logos":[]}}
        """
        let details = try TMDBClient.decoder.decode(TMDBShowDetails.self, from: Data(json.utf8)).details(region: "DK")
        XCTAssertEqual(details.related, [])
        XCTAssertNil(details.tagline)
        XCTAssertNil(details.runtime)
        XCTAssertNil(details.rating, "5 votes is too few to show")
        XCTAssertEqual(details.certification, "TV-Y")
        XCTAssertNil(details.logoPath)
        XCTAssertEqual(details.makers, ["Joe Brumm"])
        XCTAssertEqual(details.network, "ABC Kids")
        XCTAssertEqual(details.cast.first?.character, "Bandit (voice)")
        XCTAssertEqual(details.cast.first?.episodeCount, 150)
    }

    func testDecodeDetailsStoredByAnOlderVersion() throws {
        let json = #"{"genres":["Animation"],"makers":[],"cast":[{"name":"Dave McCormack","character":"Bandit"}]}"#
        let details = try JSONDecoder().decode(TMDBDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.schema, 0, "so it's fetched again")
        XCTAssertEqual(details.related, [])
        XCTAssertNil(details.cast.first?.id)
    }

    func testMoreLikeThis() {
        func details(_ genres: [String], rating: Double? = nil, related: [Int] = []) -> TMDBDetails {
            TMDBDetails(tagline: nil, genres: genres, runtime: nil, rating: rating, certification: nil, logoPath: nil,
                        makers: [], network: nil, cast: [], related: related)
        }
        let target = details(["Action", "Science Fiction", "Thriller"], related: [30, 10])
        let candidates: [MoreLikeThis.Candidate] = [
            .init(tmdbID: 1, details: details(["Action", "Science Fiction"], rating: 6)),
            .init(tmdbID: 2, details: details(["Action"])),                       // one genre of three: not enough
            .init(tmdbID: 10, details: details(["Comedy"])),                      // TMDB says so, whatever the genres
            .init(tmdbID: 3, details: details(["Action", "Science Fiction", "Thriller"], rating: 5)),
            .init(tmdbID: nil, details: nil),
            .init(tmdbID: 30, details: nil),
            .init(tmdbID: 4, details: details(["Science Fiction", "Thriller"], rating: 8)),
        ]
        XCTAssertEqual(MoreLikeThis.rank(for: target, candidates: candidates), [5, 2, 3, 6, 0])
        XCTAssertEqual(MoreLikeThis.rank(for: target, candidates: candidates, limit: 2), [5, 2])
        XCTAssertEqual(MoreLikeThis.rank(for: nil, candidates: candidates), [])
        // A single genre only needs that one.
        XCTAssertEqual(MoreLikeThis.rank(for: details(["Action"]), candidates: Array(candidates.prefix(2))), [0, 1])
    }

    func testMovieYearTolerance() throws {
        let results = [
            TMDBMovie(id: 1, title: "Moana", releaseDate: "2026-07-10", overview: nil, posterPath: nil, backdropPath: nil),
            TMDBMovie(id: 2, title: "Moana", releaseDate: "2016-11-23", overview: nil, posterPath: nil, backdropPath: nil),
        ]
        XCTAssertEqual(TMDBClient.bestMovie(results, title: "Moana", year: 2016)?.id, 2)
        XCTAssertEqual(TMDBClient.bestMovie(results, title: "Moana", year: 2017)?.id, 2)
        XCTAssertNil(TMDBClient.bestMovie(results, title: "Moana", year: 1990))
    }

    func testImageURL() {
        XCTAssertEqual(TMDBClient.imageURL("/abc.jpg")?.absoluteString, "https://image.tmdb.org/t/p/w500/abc.jpg")
        XCTAssertNil(TMDBClient.imageURL(nil))
    }
}
