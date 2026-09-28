import Foundation

public struct FileEntry: Sendable, Hashable {
    public var name: String
    /// Share-relative, no leading slash: "movies/Moana (2016)/Moana (2016).mp4"
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public init(name: String, path: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Anything that can list a directory. The SMB share in the app, an in-memory
/// tree in tests.
public protocol FileSource: Sendable {
    func list(_ path: String) async throws -> [FileEntry]
}

public enum LibraryKind: String, Codable, Sendable, CaseIterable {
    case movies
    case shows
}

public struct SubtitleFile: Sendable, Hashable, Codable {
    public var path: String
    public var label: String
    public var languageCode: String?
    public var isForced: Bool
}

public struct ScannedVideo: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var modified: Date?
    public var subtitles: [SubtitleFile]
    /// A same-named .jpg next to the video (Pinchflat writes these).
    public var thumbnailPath: String?

    public var fileName: String { (path as NSString).lastPathComponent }
}

public struct ScannedMovie: Sendable, Hashable {
    public var title: String
    public var year: Int?
    public var video: ScannedVideo
    public var posterPath: String?
}

public struct ScannedEpisode: Sendable, Hashable {
    public var season: Int
    /// nil for files with no SxxEyy, e.g. a special named only by its title.
    public var episode: Int?
    public var episodeEnd: Int?
    public var title: String?
    public var video: ScannedVideo
}

public struct ScannedShow: Sendable, Hashable {
    /// The show folder, used as its identity.
    public var path: String
    public var title: String
    public var year: Int?
    public var country: String?
    public var posterPath: String?
    public var episodes: [ScannedEpisode]
}

public struct ScanResult: Sendable {
    public var movies: [ScannedMovie] = []
    public var shows: [ScannedShow] = []
}

/// Walks one library folder on the share and works out what's in it. Handles
/// the layouts actually found on Bucket_A: Radarr-style "Title (Year)/" movie
/// folders, plain folders of movies, shows with and without "Season N/"
/// folders, and Pinchflat's YouTube downloads.
public struct LibraryScanner: Sendable {
    public var source: any FileSource
    /// Directory depth below the library root to descend. The deepest real
    /// layout is Show/Season NA/Show - Season 2026/file.
    public var maxDepth = 4

    public init(source: any FileSource) {
        self.source = source
    }

    public func scan(root: String, kind: LibraryKind) async throws -> ScanResult {
        let top = try await source.list(root).filter { !Self.isIgnored($0.name) }
        var result = ScanResult()
        switch kind {
        case .movies:
            // Loose files in the root are movies named by filename.
            result.movies += Self.movies(in: top, folderTitle: nil, subsDirs: [])
            for dir in top where dir.isDirectory {
                result.movies += try await scanMovieFolder(dir, depth: 1)
            }
            result.movies.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .shows:
            for dir in top where dir.isDirectory {
                if let show = try await scanShow(dir) { result.shows.append(show) }
            }
            result.shows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    // MARK: Movies

    private func scanMovieFolder(_ dir: FileEntry, depth: Int) async throws -> [ScannedMovie] {
        let entries = try await listBelowRoot(dir.path).filter { !Self.isIgnored($0.name) }
        let subdirs = entries.filter(\.isDirectory)
        let subsDirs = subdirs.filter { Self.isSubsFolder($0.name) }
        var subsFiles: [FileEntry] = []
        for s in subsDirs {
            subsFiles += try await listBelowRoot(s.path).filter { !$0.isDirectory && !Self.isIgnored($0.name) && Self.isSubtitle($0.name) }
        }

        var found = Self.movies(in: entries, folderTitle: dir.name, subsDirs: subsFiles)
        if depth < maxDepth {
            for sub in subdirs where !Self.isSubsFolder(sub.name) && !Self.isExtrasFolder(sub.name) {
                found += try await scanMovieFolder(sub, depth: depth + 1)
            }
        }
        return found
    }

    /// One folder's worth of files. A folder holding a single main video is
    /// named after the folder, which is the cleaner of the two names; a
    /// folder holding several is a collection, so each is named by its file.
    static func movies(in entries: [FileEntry], folderTitle: String?, subsDirs: [FileEntry]) -> [ScannedMovie] {
        let videos = mainVideos(entries)
        guard !videos.isEmpty else { return [] }
        let subtitles = entries.filter { isSubtitle($0.name) }
        let images = entries.filter { isImage($0.name) }
        let folderPoster = images.first { ["poster", "folder", "cover", "movie"].contains(NameParser.stripExtension($0.name).lowercased()) }

        return videos.map { v in
            let stem = NameParser.stripExtension(v.name)
            var parsed: ParsedTitle
            if videos.count == 1, let folderTitle {
                parsed = NameParser.parseTitle(folderTitle)
                // "Toy Story 1/Toy.Story.1995.1080p.BRrip.x264.YIFY.mp4"
                if parsed.year == nil { parsed.year = NameParser.parseTitle(v.name).year }
            } else {
                parsed = NameParser.parseTitle(v.name)
            }
            // With one movie in the folder every subtitle belongs to it; with
            // several, only those named after the video.
            let own = videos.count == 1 ? subtitles + subsDirs : subtitles.filter { $0.name.hasPrefix(stem) }
            let video = ScannedVideo(
                path: v.path, size: v.size, modified: v.modified,
                subtitles: own.map { subtitle($0, videoStem: stem) },
                thumbnailPath: nil
            )
            let poster = images.first { NameParser.stripExtension($0.name) == stem || NameParser.stripExtension($0.name) == "\(stem)-poster" }
            return ScannedMovie(title: parsed.title, year: parsed.year, video: video,
                                posterPath: (poster ?? (videos.count == 1 ? folderPoster : nil))?.path)
        }
    }

    // MARK: Shows

    private func scanShow(_ dir: FileEntry) async throws -> ScannedShow? {
        let parsed = NameParser.parseShowFolder(dir.name)
        var episodes: [ScannedEpisode] = []
        var poster: String?
        try await collectEpisodes(in: dir, seasonHint: nil, depth: 1, into: &episodes, poster: &poster)
        guard !episodes.isEmpty else { return nil }
        episodes.sort {
            ($0.season, $0.episode ?? Int.max, $0.video.fileName) < ($1.season, $1.episode ?? Int.max, $1.video.fileName)
        }
        return ScannedShow(path: dir.path, title: parsed.title, year: parsed.year, country: parsed.country,
                           posterPath: poster, episodes: episodes)
    }

    private func collectEpisodes(in dir: FileEntry, seasonHint: Int?, depth: Int,
                                 into episodes: inout [ScannedEpisode], poster: inout String?) async throws {
        let entries = try await listBelowRoot(dir.path).filter { !Self.isIgnored($0.name) }
        let subtitles = entries.filter { Self.isSubtitle($0.name) }
        let images = entries.filter { Self.isImage($0.name) }
        if depth == 1, poster == nil {
            poster = images.first { ["poster", "folder", "show", "cover"].contains(NameParser.stripExtension($0.name).lowercased()) }?.path
        }

        // Parsed once per folder, not once per video: a YouTube channel can
        // hold hundreds of each.
        let subtitleEpisodes = subtitles.map { NameParser.parseEpisode($0.name) }

        for v in Self.mainVideos(entries) {
            let stem = NameParser.stripExtension(v.name)
            let parsed = NameParser.parseEpisode(v.name)
            // Match subtitles by filename first, then by the same SxxEyy - some
            // grabbers name the subtitle after the release, not the file.
            var own = subtitles.filter { $0.name.hasPrefix(stem + ".") }
            if own.isEmpty, let p = parsed {
                own = zip(subtitles, subtitleEpisodes)
                    .filter { $0.1?.season == p.season && $0.1?.episode == p.episode }
                    .map(\.0)
            }
            let thumb = images.first {
                let s = NameParser.stripExtension($0.name)
                return s == stem || s == "\(stem)-thumb"
            }
            let video = ScannedVideo(
                path: v.path, size: v.size, modified: v.modified,
                subtitles: own.map { Self.subtitle($0, videoStem: stem) },
                thumbnailPath: thumb?.path
            )
            if let parsed {
                episodes.append(ScannedEpisode(season: parsed.season, episode: parsed.episode,
                                               episodeEnd: parsed.episodeEnd, title: parsed.title, video: video))
            } else {
                episodes.append(ScannedEpisode(season: seasonHint ?? 0, episode: nil, episodeEnd: nil,
                                               title: NameParser.looseEpisodeTitle(v.name), video: video))
            }
        }

        guard depth < maxDepth else { return }
        for sub in entries where sub.isDirectory && !Self.isExtrasFolder(sub.name) && !Self.isSubsFolder(sub.name) {
            let hint = NameParser.seasonNumber(folder: sub.name) ?? seasonHint
            try await collectEpisodes(in: sub, seasonHint: hint, depth: depth + 1, into: &episodes, poster: &poster)
        }
    }

    /// A folder that vanished or can't be read mid-scan is skipped. Anything
    /// else - a dropped connection - still fails the scan, because a
    /// half-empty result would make the app forget what it had.
    private func listBelowRoot(_ path: String) async throws -> [FileEntry] {
        do {
            return try await source.list(path)
        } catch let SMBError.folder(_, code, _) where [ENOENT, EACCES, EPERM, ENOTDIR].contains(code) {
            return []
        }
    }

    // MARK: Classification

    static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("@") || name.hasPrefix("#") || name == "$RECYCLE.BIN"
    }

    static func isVideo(_ name: String) -> Bool { MediaExtensions.video.contains(NameParser.fileExtension(name)) }
    static func isSubtitle(_ name: String) -> Bool { MediaExtensions.subtitle.contains(NameParser.fileExtension(name)) }
    static func isImage(_ name: String) -> Bool { MediaExtensions.image.contains(NameParser.fileExtension(name)) }

    static func isSubsFolder(_ name: String) -> Bool {
        ["subs", "subtitles", "sub"].contains(name.lowercased())
    }

    static func isExtrasFolder(_ name: String) -> Bool {
        ["extras", "featurettes", "behind the scenes", "deleted scenes", "interviews", "scenes",
         "shorts", "trailers", "sample", "samples", "other", "bonus"].contains(name.lowercased())
    }

    /// Videos worth listing: not samples, not trailers.
    static func mainVideos(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { e in
            guard !e.isDirectory, isVideo(e.name) else { return false }
            let stem = NameParser.stripExtension(e.name).lowercased()
            let tokens = stem.split(whereSeparator: { " ._-".contains($0) })
            // Only small "sample" files: a real movie could have the word in its title.
            if tokens.contains("sample"), e.size > 0, e.size < 400_000_000 { return false }
            if stem.hasSuffix("-trailer") || stem == "trailer" { return false }
            return true
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func subtitle(_ e: FileEntry, videoStem: String) -> SubtitleFile {
        let p = NameParser.parseSubtitle(fileName: e.name, videoStem: videoStem)
        return SubtitleFile(path: e.path, label: p.label, languageCode: p.languageCode, isForced: p.isForced)
    }
}
