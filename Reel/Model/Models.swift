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
    /// "https://..." for TMDB art, "smb:<path>" for an image on the share (SMB or WebDAV).
    var posterRef: String?
    var backdropRef: String?
    var tmdbID: Int?
    var metadataFetched: Bool = false
    var addedAt: Date
    /// When the newest episode arrived, for "Recently Added".
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Video.show) var episodes: [Video] = []
    /// JSON-encoded TMDBDetails: cast, genres and the like. See `DetailsLoader`.
    var detailsJSON: Data?
    var detailsFetchedAt: Date?

    init(path: String, libraryID: UUID, title: String, addedAt: Date) {
        self.path = path
        self.libraryID = libraryID
        self.title = title
        self.addedAt = addedAt
        self.updatedAt = addedAt
    }

    var details: TMDBDetails? { TMDBDetails(json: detailsJSON) }

    var sortedEpisodes: [Video] {
        episodes.sorted {
            ($0.season, $0.episode ?? Int.max, $0.path) < ($1.season, $1.episode ?? Int.max, $1.path)
        }
    }

    var seasons: [Int] { Self.seasons(of: episodes) }

    static func seasons(of episodes: [Video]) -> [Int] {
        Array(Set(episodes.map(\.season))).sorted { season0Last($0, $1) }
    }

    /// The episode to offer on the show page: one in progress, else the one
    /// after the last watched, else the first.
    var nextUp: Video? { Self.nextUp(in: sortedEpisodes) }

    /// `nextUp` from episodes already in `sortedEpisodes` order, for views
    /// that need several of these at once and shouldn't sort for each.
    static func nextUp(in sorted: [Video]) -> Video? {
        let eps = sorted.filter { $0.season != 0 }
        if let inProgress = eps.filter({ $0.isInProgress }).max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }) {
            return inProgress
        }
        if let lastWatched = eps.lastIndex(where: \.watched) {
            return eps.indices.contains(lastWatched + 1) ? eps[lastWatched + 1] : nil
        }
        return eps.first ?? sorted.first
    }

    /// Stand-ins for when there's no poster, best first: an episode's still or
    /// thumbnail, then frames from the first few episodes, so one file VLC
    /// can't read doesn't leave the show blank.
    var fallbackRefs: [String?] {
        let sorted = sortedEpisodes
        let real = sorted.filter { $0.season != 0 }
        let eps = real.isEmpty ? sorted : real
        return [eps.lazy.compactMap(\.posterRef).first] + eps.prefix(3).map(\.frameRef)
    }

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
    /// A movie's JSON-encoded TMDBDetails. See `DetailsLoader`.
    var detailsJSON: Data?
    var detailsFetchedAt: Date?
    var fileSize: Int64 = 0
    var addedAt: Date

    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
    var lastPlayedAt: Date?
    var watched: Bool = false
    /// When position or watched last changed, here or on another install.
    /// Nil until then; decides which side wins when progress is synced.
    var progressUpdatedAt: Date?

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

    var details: TMDBDetails? { TMDBDetails(json: detailsJSON) }

    var fileName: String { (path as NSString).lastPathComponent }

    /// A frame from the file itself, for when there's no poster or still.
    var frameRef: String { "frame:" + path }

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
    /// position, the way every streaming app does. Getting properly into
    /// something already watched makes it a rewatch in progress, so it gets a
    /// resume point and shows in Keep Watching.
    func recordProgress(position: Double, duration: Double) {
        if duration > 0 { durationSeconds = duration }
        lastPlayedAt = .now
        if Self.isFinished(position: position, duration: durationSeconds) {
            watched = true
            positionSeconds = 0
        } else {
            if position > 30 { watched = false }
            positionSeconds = position
        }
        progressChanged()
    }

    /// Close enough to the end to count as watched: past 92%, or into the
    /// last two minutes (credits) of anything over ten.
    static func isFinished(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position / duration > 0.92 || (duration - position < 120 && duration > 600)
    }

    func setWatched(_ value: Bool) {
        watched = value
        positionSeconds = 0
        if value { lastPlayedAt = .now }
        progressChanged()
    }

    /// What goes to the share for this file, once there's anything to say.
    var watchProgress: WatchProgress? {
        progressUpdatedAt.map {
            WatchProgress(position: positionSeconds, duration: durationSeconds, watched: watched, updatedAt: $0)
        }
    }

    /// Takes progress from another install if it's newer than what's here.
    func adopt(_ remote: WatchProgress) {
        guard remote.updatedAt > (progressUpdatedAt ?? .distantPast) else { return }
        positionSeconds = remote.position
        if remote.duration > 0 { durationSeconds = remote.duration }
        watched = remote.watched
        lastPlayedAt = max(lastPlayedAt ?? .distantPast, remote.updatedAt)
        progressUpdatedAt = remote.updatedAt
    }

    private func progressChanged() {
        progressUpdatedAt = .now
        NotificationCenter.default.post(name: .watchProgressChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted when a video's position or watched state changes on this device.
    static let watchProgressChanged = Notification.Name("watchProgressChanged")
}

extension TMDBDetails {
    /// Decoded once per distinct blob and kept: pages, grids and browse
    /// rows ask for the same titles' details on every redraw.
    init?(json: Data?) {
        guard let json else { return nil }
        if let kept = detailsCache.object(forKey: json as NSData) {
            self = kept.details
            return
        }
        guard let decoded = try? JSONDecoder().decode(TMDBDetails.self, from: json) else { return nil }
        detailsCache.setObject(DecodedDetails(decoded), forKey: json as NSData)
        self = decoded
    }
}

private final class DecodedDetails {
    let details: TMDBDetails
    init(_ details: TMDBDetails) { self.details = details }
}

/// Thread-safe, so the detached decodes (`decodeDetails`) share it.
private let detailsCache: NSCache<NSData, DecodedDetails> = {
    let cache = NSCache<NSData, DecodedDetails>()
    cache.countLimit = 3000
    return cache
}()

extension Video {
    /// What a collection's filters look at, given this movie's decoded
    /// details and its library's folder.
    func collectionCandidate(details: TMDBDetails?, library: String) -> CollectionCandidate {
        CollectionCandidate(library: library, isMovie: true, year: year, details: details,
                            runtimeMinutes: durationSeconds > 0 ? Int(durationSeconds / 60) : nil)
    }
}

extension Show {
    func collectionCandidate(details: TMDBDetails?, library: String) -> CollectionCandidate {
        CollectionCandidate(library: library, isMovie: false, year: year, details: details, runtimeMinutes: nil)
    }
}
