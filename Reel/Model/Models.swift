import Foundation
import ReelCore
import SwiftData

/// A TV show folder. Episodes are `Video`s pointing back at it.
@Model
final class Show {
    @Attribute(.unique) var path: String
    var libraryID: UUID
    var title: String
    var year: Int?
    var country: String?
    var overview: String?
    /// "https://..." for TMDB art, "smb:<path>" for an image on the share.
    var posterRef: String?
    var backdropRef: String?
    var tmdbID: Int?
    var metadataFetched: Bool = false
    var addedAt: Date
    /// When the newest episode arrived, for "Recently Added".
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Video.show) var episodes: [Video] = []

    init(path: String, libraryID: UUID, title: String, addedAt: Date) {
        self.path = path
        self.libraryID = libraryID
        self.title = title
        self.addedAt = addedAt
        self.updatedAt = addedAt
    }

    var sortedEpisodes: [Video] {
        episodes.sorted {
            ($0.season, $0.episode ?? Int.max, $0.path) < ($1.season, $1.episode ?? Int.max, $1.path)
        }
    }

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted { season0Last($0, $1) } }

    /// The episode to offer on the show page: one in progress, else the one
    /// after the last watched, else the first.
    var nextUp: Video? {
        let eps = sortedEpisodes.filter { $0.season != 0 }
        if let inProgress = eps.filter({ $0.isInProgress }).max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }) {
            return inProgress
        }
        if let lastWatched = eps.lastIndex(where: \.watched) {
            return eps.indices.contains(lastWatched + 1) ? eps[lastWatched + 1] : nil
        }
        return eps.first ?? sortedEpisodes.first
    }

    var hasStarted: Bool { episodes.contains { $0.watched || $0.isInProgress } }
    var lastPlayedAt: Date? { episodes.compactMap(\.lastPlayedAt).max() }
    var unwatchedCount: Int { episodes.filter { !$0.watched }.count }
}

/// Specials (season 0) sort after the real seasons.
func season0Last(_ a: Int, _ b: Int) -> Bool {
    if a == 0 { return false }
    if b == 0 { return true }
    return a < b
}

/// One playable file: a movie, or an episode of a `Show`.
@Model
final class Video {
    @Attribute(.unique) var path: String
    var libraryID: UUID
    var isMovie: Bool
    var title: String
    var year: Int?
    var season: Int = 0
    var episode: Int?
    var episodeEnd: Int?
    var overview: String?
    /// Movie poster, or episode still/thumbnail. Same format as Show.posterRef.
    var posterRef: String?
    var backdropRef: String?
    var tmdbID: Int?
    var runtimeMinutes: Int?
    var metadataFetched: Bool = false
    /// JSON-encoded [SubtitleFile]. Stored as Data rather than a Codable
    /// array, which SwiftData has been unreliable with.
    var subtitlesJSON: Data?
    var fileSize: Int64 = 0
    var addedAt: Date

    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
    var lastPlayedAt: Date?
    var watched: Bool = false

    var show: Show?

    init(path: String, libraryID: UUID, isMovie: Bool, title: String, addedAt: Date) {
        self.path = path
        self.libraryID = libraryID
        self.isMovie = isMovie
        self.title = title
        self.addedAt = addedAt
    }

    var subtitles: [SubtitleFile] {
        get { subtitlesJSON.flatMap { try? JSONDecoder().decode([SubtitleFile].self, from: $0) } ?? [] }
        set { subtitlesJSON = try? JSONEncoder().encode(newValue) }
    }

    var fileName: String { (path as NSString).lastPathComponent }

    var isInProgress: Bool { !watched && positionSeconds > 30 }

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, positionSeconds / durationSeconds)
    }

    /// "S2 · E7" / "S4 · E7–8" / "Special"
    var episodeCode: String {
        guard let episode else { return season == 0 ? "Special" : "S\(season)" }
        let e = episodeEnd.map { "E\(episode)–\($0)" } ?? "E\(episode)"
        return season == 0 ? "Special \(e)" : "S\(season) · \(e)"
    }

    /// Title for rows that mix movies and episodes.
    var displayTitle: String { isMovie ? title : (show?.title ?? title) }
    var displaySubtitle: String {
        if isMovie { return year.map(String.init) ?? "" }
        return "\(episodeCode) · \(title)"
    }

    /// Records playback. Near the end counts as watched and resets the
    /// position, the way every streaming app does.
    func recordProgress(position: Double, duration: Double) {
        if duration > 0 { durationSeconds = duration }
        lastPlayedAt = .now
        let remaining = durationSeconds - position
        if durationSeconds > 0, position / durationSeconds > 0.92 || (remaining < 120 && durationSeconds > 600) {
            watched = true
            positionSeconds = 0
        } else {
            positionSeconds = position
        }
    }

    func setWatched(_ value: Bool) {
        watched = value
        positionSeconds = 0
        if value { lastPlayedAt = .now }
    }
}
