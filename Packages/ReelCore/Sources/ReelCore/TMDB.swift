import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TMDBMovie: Decodable, Sendable, Equatable {
    public var id: Int
    public var title: String
    public var releaseDate: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?

    public var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }
}

public struct TMDBShow: Decodable, Sendable, Equatable {
    public var id: Int
    public var name: String
    public var firstAirDate: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var originCountry: [String]?

    public var year: Int? { firstAirDate.flatMap { Int($0.prefix(4)) } }
}

public struct TMDBEpisode: Decodable, Sendable, Equatable {
    public var episodeNumber: Int
    public var seasonNumber: Int
    public var name: String?
    public var overview: String?
    public var stillPath: String?
    public var runtime: Int?
    public var airDate: String?
}

public struct TMDBSeason: Decodable, Sendable, Equatable {
    public var seasonNumber: Int
    public var posterPath: String?
    public var episodes: [TMDBEpisode]
}

/// What a movie or show page shows beyond the scan's basics. Kept as JSON on
/// the model, so it's encoded with plain keys rather than TMDB's.
public struct TMDBDetails: Codable, Sendable, Equatable {
    /// Bumped when a field is added, so details fetched before it are
    /// fetched again rather than missing it until they're a month old.
    public static let currentSchema = 2
    public var schema = 0

    public var tagline: String?
    public var genres: [String] = []
    /// Minutes; a typical episode's for a show.
    public var runtime: Int?
    /// Out of 10, nil when too few people have rated it to mean much.
    public var rating: Double?
    /// "PG", "TV-Y", "12", for the region asked for.
    public var certification: String?
    /// The title as artwork, a transparent PNG.
    public var logoPath: String?
    /// Directors of a movie, creators of a show.
    public var makers: [String] = []
    public var network: String?
    public var cast: [TMDBCastMember] = []
    /// TMDB's recommended and similar titles, best first: movie IDs for a
    /// movie, show IDs for a show.
    public var related: [Int] = []

    init(tagline: String?, genres: [String], runtime: Int?, rating: Double?, certification: String?, logoPath: String?,
         makers: [String], network: String?, cast: [TMDBCastMember], related: [Int]) {
        schema = Self.currentSchema
        self.tagline = tagline
        self.genres = genres
        self.runtime = runtime
        self.rating = rating
        self.certification = certification
        self.logoPath = logoPath
        self.makers = makers
        self.network = network
        self.cast = cast
        self.related = related
    }

    /// Tolerates JSON stored by an older version, which lacks newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        certification = try c.decodeIfPresent(String.self, forKey: .certification)
        logoPath = try c.decodeIfPresent(String.self, forKey: .logoPath)
        makers = try c.decodeIfPresent([String].self, forKey: .makers) ?? []
        network = try c.decodeIfPresent(String.self, forKey: .network)
        cast = try c.decodeIfPresent([TMDBCastMember].self, forKey: .cast) ?? []
        related = try c.decodeIfPresent([Int].self, forKey: .related) ?? []
    }
}

public struct TMDBCastMember: Codable, Sendable, Equatable, Hashable {
    /// TMDB's person ID, the same across every title they're in.
    public var id: Int?
    public var name: String
    public var character: String?
    public var profilePath: String?
    /// Episodes they're in, for a show.
    public var episodeCount: Int?

    public init(id: Int?, name: String, character: String? = nil, profilePath: String? = nil, episodeCount: Int? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profilePath = profilePath
        self.episodeCount = episodeCount
    }
}

/// `person/{id}`, for the page listing someone's titles.
public struct TMDBPerson: Decodable, Sendable, Equatable {
    public var name: String
    public var biography: String?
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    public var knownForDepartment: String?
    public var profilePath: String?
}

/// Just the IDs from a page of `recommendations` or `similar`.
struct TMDBIDPage: Decodable {
    struct Item: Decodable { var id: Int }
    var results: [Item]

    /// Recommendations (what people who liked it watched) first, then
    /// similar (shared genres and keywords), without repeats.
    static func merge(_ pages: TMDBIDPage?...) -> [Int] {
        var seen = Set<Int>()
        return pages.flatMap { $0?.results ?? [] }.map(\.id).filter { seen.insert($0).inserted }
    }
}

/// `movie/{id}` with credits, release dates and images appended.
struct TMDBMovieDetails: Decodable {
    struct Named: Decodable { var name: String }
    struct Credits: Decodable {
        struct Cast: Decodable { var id: Int?; var name: String; var character: String?; var profilePath: String? }
        struct Crew: Decodable { var name: String; var job: String? }
        var cast: [Cast]
        var crew: [Crew]
    }
    struct ReleaseDates: Decodable {
        struct Country: Decodable {
            struct Release: Decodable { var certification: String? }
            var iso31661: String
            var releaseDates: [Release]
        }
        var results: [Country]
    }

    var tagline: String?
    var genres: [Named]?
    var runtime: Int?
    var voteAverage: Double?
    var voteCount: Int?
    var credits: Credits?
    var releaseDates: ReleaseDates?
    var images: TMDBImages?
    var recommendations: TMDBIDPage?
    var similar: TMDBIDPage?

    func details(region: String) -> TMDBDetails {
        let certifications = { (code: String) in
            releaseDates?.results.first { $0.iso31661 == code }?.releaseDates
                .compactMap(\.certification).first { !$0.isEmpty }
        }
        return TMDBDetails(
            tagline: tagline.nonEmpty,
            genres: genres?.map(\.name) ?? [],
            runtime: runtime.flatMap { $0 > 0 ? $0 : nil },
            rating: TMDBImages.rating(voteAverage, count: voteCount),
            certification: certifications(region) ?? certifications("US"),
            logoPath: images?.bestLogo,
            makers: credits?.crew.filter { $0.job == "Director" }.map(\.name) ?? [],
            network: nil,
            cast: (credits?.cast ?? []).prefix(TMDBImages.castLimit).map {
                TMDBCastMember(id: $0.id, name: $0.name, character: $0.character.nonEmpty, profilePath: $0.profilePath)
            },
            related: TMDBIDPage.merge(recommendations, similar))
    }
}

/// `tv/{id}` with aggregate credits, content ratings and images appended.
struct TMDBShowDetails: Decodable {
    struct Named: Decodable { var name: String }
    struct Credits: Decodable {
        struct Cast: Decodable {
            struct Role: Decodable { var character: String?; var episodeCount: Int? }
            var id: Int?
            var name: String
            var profilePath: String?
            var roles: [Role]?
            var totalEpisodeCount: Int?
        }
        var cast: [Cast]
    }
    struct Ratings: Decodable {
        struct Country: Decodable { var iso31661: String; var rating: String? }
        var results: [Country]
    }

    var tagline: String?
    var genres: [Named]?
    var episodeRunTime: [Int]?
    var voteAverage: Double?
    var voteCount: Int?
    var createdBy: [Named]?
    var networks: [Named]?
    var aggregateCredits: Credits?
    var contentRatings: Ratings?
    var images: TMDBImages?
    var recommendations: TMDBIDPage?
    var similar: TMDBIDPage?

    func details(region: String) -> TMDBDetails {
        let rating = { (code: String) in
            contentRatings?.results.first { $0.iso31661 == code }?.rating.nonEmpty
        }
        return TMDBDetails(
            tagline: tagline.nonEmpty,
            genres: genres?.map(\.name) ?? [],
            runtime: episodeRunTime?.first { $0 > 0 },
            rating: TMDBImages.rating(voteAverage, count: voteCount),
            certification: rating(region) ?? rating("US"),
            logoPath: images?.bestLogo,
            makers: createdBy?.map(\.name) ?? [],
            network: networks?.first?.name,
            cast: (aggregateCredits?.cast ?? []).prefix(TMDBImages.castLimit).map { person in
                // The biggest part first; a voice actor can have several.
                let role = person.roles?.max { ($0.episodeCount ?? 0) < ($1.episodeCount ?? 0) }
                return TMDBCastMember(id: person.id, name: person.name, character: role?.character.nonEmpty,
                                      profilePath: person.profilePath, episodeCount: person.totalEpisodeCount)
            },
            related: TMDBIDPage.merge(recommendations, similar))
    }
}

struct TMDBImages: Decodable {
    struct Image: Decodable { var filePath: String; var iso6391: String? }
    var logos: [Image]?

    static let castLimit = 20

    /// TMDB lists the most voted first. SVGs aren't something UIImage reads.
    var bestLogo: String? {
        logos?.first { $0.filePath.hasSuffix(".png") }?.filePath
    }

    static func rating(_ average: Double?, count: Int?) -> Double? {
        guard let average, average > 0, (count ?? 0) >= 20 else { return nil }
        return average
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}

struct TMDBPage<T: Decodable>: Decodable {
    var results: [T]
}

public enum TMDBError: LocalizedError {
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .http(401): "TMDB rejected the API key."
        case .http(let code): "TMDB returned HTTP \(code)."
        }
    }
}

/// The handful of TMDB v3 endpoints the library needs. Accepts either a v3
/// API key or a v4 read access token - TMDB's settings page shows both.
public struct TMDBClient: Sendable {
    public var apiKey: String
    public var language: String
    private let session: URLSession

    public init(apiKey: String, language: String = "en-US", session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.session = session
    }

    public static func imageURL(_ path: String?, size: String = "w500") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    public func searchMovie(title: String, year: Int?) async throws -> TMDBMovie? {
        var query = ["query": title]
        if let year { query["year"] = String(year) }
        let page: TMDBPage<TMDBMovie> = try await get("search/movie", query)
        if let hit = Self.bestMovie(page.results, title: title, year: year) { return hit }
        // Folder years are sometimes a year off the TMDB release date.
        guard year != nil else { return nil }
        let loose: TMDBPage<TMDBMovie> = try await get("search/movie", ["query": title])
        return Self.bestMovie(loose.results, title: title, year: year)
    }

    public func searchShow(title: String, year: Int?, country: String?) async throws -> TMDBShow? {
        var query = ["query": title]
        if let year { query["first_air_date_year"] = String(year) }
        let page: TMDBPage<TMDBShow> = try await get("search/tv", query)
        return Self.bestShow(page.results, country: country)
    }

    public func season(showID: Int, number: Int) async throws -> TMDBSeason {
        try await get("tv/\(showID)/season/\(number)", [:])
    }

    /// Cast, genres, ratings and a title logo for a movie. `region` picks
    /// the age rating, e.g. "DK"; the US one is used where it has none.
    public func movieDetails(id: Int, region: String) async throws -> TMDBDetails {
        let raw: TMDBMovieDetails = try await get("movie/\(id)", [
            "append_to_response": "credits,release_dates,images,recommendations,similar",
            "include_image_language": imageLanguages,
        ])
        return raw.details(region: region)
    }

    /// The same for a show, with its cast across every season.
    public func showDetails(id: Int, region: String) async throws -> TMDBDetails {
        let raw: TMDBShowDetails = try await get("tv/\(id)", [
            "append_to_response": "aggregate_credits,content_ratings,images,recommendations,similar",
            "include_image_language": imageLanguages,
        ])
        return raw.details(region: region)
    }

    /// Someone's biography and the like, for the page of their titles.
    public func person(id: Int) async throws -> TMDBPerson {
        try await get("person/\(id)", [:])
    }

    /// Logos in the app's language, then English, then ones with no text.
    private var imageLanguages: String {
        var languages = [String(language.prefix(2))]
        for fallback in ["en", "null"] where !languages.contains(fallback) { languages.append(fallback) }
        return languages.joined(separator: ",")
    }

    static func bestMovie(_ results: [TMDBMovie], title: String, year: Int?) -> TMDBMovie? {
        guard let year else { return results.first }
        return results.first { m in m.year.map { abs($0 - year) <= 1 } ?? false }
    }

    /// "The Office (US)" and "The Office" share a name; the country in the
    /// folder name decides.
    static func bestShow(_ results: [TMDBShow], country: String?) -> TMDBShow? {
        if let country, let match = results.first(where: { $0.originCountry?.contains(country) ?? false }) {
            return match
        }
        return results.first
    }

    private var usesBearerToken: Bool { apiKey.count > 40 }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        var c = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        items.append(URLQueryItem(name: "include_adult", value: "false"))
        if !usesBearerToken { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        c.queryItems = items.sorted { $0.name < $1.name }

        var request = URLRequest(url: c.url!)
        // With no internet (the router's own WiFi, on a plane) its DNS can
        // take a long time to give up; better to find out quickly.
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearerToken { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // TMDB rate-limits with 429; a first library scan can hit it.
            if status == 429, attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }
            guard (200..<300).contains(status) else { throw TMDBError.http(status) }
            return try Self.decoder.decode(T.self, from: data)
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
