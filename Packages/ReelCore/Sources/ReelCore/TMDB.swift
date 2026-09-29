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
