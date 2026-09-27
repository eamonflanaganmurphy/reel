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
