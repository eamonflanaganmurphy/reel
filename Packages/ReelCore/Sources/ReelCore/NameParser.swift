import Foundation

public enum MediaExtensions {
    public static let video: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "webm", "mov", "ts", "m2ts", "wmv", "mpg", "mpeg", "flv", "ogv",
    ]
    public static let subtitle: Set<String> = ["srt", "ass", "ssa", "vtt"]
    public static let image: Set<String> = ["jpg", "jpeg", "png", "webp"]
}

public struct ParsedTitle: Equatable, Sendable {
    public var title: String
    public var year: Int?
    /// "US" in "The Office (US)". Used to pick between same-named shows on TMDB.
    public var country: String?
}

public struct ParsedEpisode: Equatable, Sendable {
    public var season: Int
    public var episode: Int
    /// Last episode of a multi-episode file, e.g. 8 for S04E07E08.
    public var episodeEnd: Int?
    public var title: String?
}

public struct ParsedSubtitle: Equatable, Sendable {
    public var label: String
    public var languageCode: String?
    public var isForced: Bool
    public var isSDH: Bool
}

/// Turns folder and release names into titles. Everything here is heuristic;
/// TMDB replaces most of it when a key is configured, so the goal is "good
/// enough to search for and to show when offline", not perfection.
public enum NameParser {

    // MARK: Movies and shows

    /// "Past Lives (2023) [2160p] [4K] [WEB] [5.1] [YTS.MX]" -> Past Lives, 2023
    /// "Anchorman The Legend of Ron Burgundy 2004 1080p PTV WEB-DL" -> ..., 2004
    public static func parseTitle(_ raw: String) -> ParsedTitle {
        var name = stripSitePrefix(stripExtension(raw))
        name = name.replacingOccurrences(of: "()", with: "")

        // "Title (Year)" wins outright - it's how Radarr names folders.
        if let m = firstMatch(#"^(.*?)[\s._-]*\((\d{4})\)"#, in: name),
           let year = Int(m[2]), plausibleYear(year), !m[1].isEmpty {
            return finishTitle(m[1], year: year)
        }

        // A bare year followed by release tags or the end of the name. Take
        // the last one so "Blade Runner 2049 2017" keeps 2049 in the title.
        let yearMatches = allMatches(#"(?<![0-9A-Za-z])((?:19|20)\d{2})(?![0-9A-Za-z])"#, in: name)
        if let m = yearMatches.last(where: { $0.range.location > 0 }),
           let year = Int(m.groups[1]), plausibleYear(year) {
            let before = (name as NSString).substring(to: m.range.location)
            if !cleanSeparators(before).isEmpty {
                return finishTitle(before, year: year)
            }
        }

        return finishTitle(cutAtReleaseTags(name), year: nil)
    }

    /// Show folders: "Bluey (2018)", "The Office (US)", "Euphoria (US)".
    public static func parseShowFolder(_ raw: String) -> ParsedTitle {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let m = firstMatch(#"^(.*?)\s*\(([A-Z]{2})\)$"#, in: name) {
            var parsed = parseTitle(m[1])
            parsed.country = m[2]
            return parsed
        }
        return parseTitle(name)
    }

    // MARK: Episodes

    private static let sxxeyy =
        #"(?i)(?:^|[\s._\-\[(])s(\d{1,4})[\s._-]?e(\d{1,4})(?:(?:[\s._-]?e|-)(\d{1,4}))?(?![0-9])"#
    private static let nxnn = #"(?i)(?:^|[\s._\-\[(])(\d{1,2})x(\d{2,3})(?![0-9])"#

    /// "Bobs.Burgers.S10E13.Three.Girls.and.A.Little.Wharfy.1080p.DSNP.WEB-DL..."
    /// "Bluey - s01e01 - Bluey ULTIMATE Christmas Compilation!..."
    /// "How I Met Your Mother S03E17 The Goat (1080p x265 Joy)"
    public static func parseEpisode(_ fileName: String) -> ParsedEpisode? {
        let name = stripSitePrefix(stripExtension(fileName))
        guard let m = firstMatchWithRange(sxxeyy, in: name) ?? firstMatchWithRange(nxnn, in: name),
              let season = Int(m.groups[1]), let episode = Int(m.groups[2])
        else { return nil }
        let end = m.groups.count > 3 ? Int(m.groups[3]) : nil
        let rest = (name as NSString).substring(from: m.range.location + m.range.length)
        return ParsedEpisode(
            season: season, episode: episode,
            episodeEnd: end.flatMap { $0 > episode ? $0 : nil },
            title: episodeTitle(from: rest)
        )
    }

    /// Title for a file with no SxxEyy: "aaf-pingu.special.pingu.at.the.wedding.party.dvdrip.xvid"
    public static func looseEpisodeTitle(_ fileName: String) -> String {
        let name = stripSitePrefix(stripExtension(fileName))
        let cut = cleanSeparators(cutAtReleaseTags(name))
        return cut.isEmpty ? cleanSeparators(name) : cut
    }

    /// "Season 1", "Season 01", "S02", "Series 3", "Specials" -> season number.
    public static func seasonNumber(folder: String) -> Int? {
        if folder.caseInsensitiveCompare("Specials") == .orderedSame { return 0 }
        if let m = firstMatch(#"(?i)^(?:season|series|s)[\s._-]*(\d{1,4})\b"#, in: folder) {
            return Int(m[1])
        }
        return nil
    }

    private static func episodeTitle(from rest: String) -> String? {
        var s = rest
        // Pinchflat and Sonarr style: "S01E01 - Title"
        if let m = firstMatch(#"^\s*-\s*(.*)$"#, in: s) { s = m[1] }
        s = cutAtReleaseTags(s)
        let t = cleanSeparators(s)
        return t.isEmpty ? nil : t
    }

    // MARK: Subtitles

    /// Sidecar subtitle label from its name relative to the video.
    /// ("Movie.da.hi.srt", video stem "Movie") -> Danish (SDH)
    /// ("2_English.srt", no stem match) -> English
    public static func parseSubtitle(fileName: String, videoStem: String?) -> ParsedSubtitle {
        let stem = stripExtension(fileName)
        var tokens: [String]
        if let v = videoStem, stem.hasPrefix(v) {
            tokens = String(stem.dropFirst(v.count)).split(separator: ".").map(String.init)
        } else {
            tokens = stem.split(separator: ".").map(String.init)
            if tokens.count > 1, tokens.contains(where: { languageName(for: $0) != nil }) {
                tokens = Array(tokens.dropFirst())
            }
        }
        var forced = false, sdh = false
        var language: String?
        var leftovers: [String] = []
        for t in tokens {
            let lower = t.lowercased()
            switch lower {
            case "forced": forced = true
            case "hi", "sdh", "cc": sdh = true
            case "default", "full": break
            default:
                if language == nil, languageName(for: lower) != nil { language = lower }
                else { leftovers.append(t) }
            }
        }
        var label: String
        if let language, let name = languageName(for: language) {
            label = name
        } else {
            // "2_English" -> "English"
            let raw = leftovers.joined(separator: " ")
            label = raw.replacingOccurrences(of: #"^\d+[_\s-]*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
            if label.isEmpty { label = "Subtitles" }
        }
        var flags: [String] = []
        if forced { flags.append("Forced") }
        if sdh { flags.append("SDH") }
        if !flags.isEmpty { label += " (\(flags.joined(separator: ", ")))" }
        return ParsedSubtitle(label: label, languageCode: language, isForced: forced, isSDH: sdh)
    }

    private static let languages: [String: String] = [
        "en": "English", "eng": "English", "da": "Danish", "dan": "Danish", "sv": "Swedish",
        "swe": "Swedish", "no": "Norwegian", "nb": "Norwegian", "nor": "Norwegian", "de": "German",
        "ger": "German", "deu": "German", "fr": "French", "fre": "French", "fra": "French",
        "es": "Spanish", "spa": "Spanish", "it": "Italian", "ita": "Italian", "nl": "Dutch",
        "dut": "Dutch", "nld": "Dutch", "fi": "Finnish", "fin": "Finnish", "pt": "Portuguese",
        "por": "Portuguese", "pl": "Polish", "pol": "Polish", "ja": "Japanese", "jpn": "Japanese",
        "ko": "Korean", "kor": "Korean", "zh": "Chinese", "chi": "Chinese", "zho": "Chinese",
        "ru": "Russian", "rus": "Russian", "ar": "Arabic", "ara": "Arabic", "hi": "Hindi",
        "is": "Icelandic", "ice": "Icelandic", "ga": "Irish", "tr": "Turkish", "el": "Greek",
        "he": "Hebrew", "cs": "Czech", "hu": "Hungarian", "ro": "Romanian", "uk": "Ukrainian",
        "english": "English", "danish": "Danish", "dansk": "Danish",
    ]

    /// Only called for tokens that aren't flags, so "hi" here never means Hindi.
    static func languageName(for code: String) -> String? {
        let c = code.lowercased()
        if c == "hi" { return nil }
        return languages[c]
    }

    // MARK: Helpers

    public static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...].lowercased()
        let known = MediaExtensions.video.union(MediaExtensions.subtitle).union(MediaExtensions.image)
            .union(["iso", "nfo"])
        return known.contains(ext) ? String(name[..<dot]) : name
    }

    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// "www.UIndex.org    -    200 Cigarettes 1999" and "[EZTVx.to]"-style prefixes.
    static func stripSitePrefix(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(
            of: #"^\s*(?:www\.)?[A-Za-z0-9-]+\.(?:org|com|to|net|me|io|cc)\s+-\s+"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        return s
    }

    private static let releaseTags: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "uhd", "hdr", "hdr10",
        "hdr10+", "dv", "dovi", "web-dl", "webdl", "webrip", "web-rip", "bluray", "blu-ray", "brrip",
        "bdrip", "dvdrip", "hdtv", "hdrip", "remux", "x264", "x265", "h264", "h265", "hevc", "avc",
        "xvid", "divx", "amzn", "nf", "dsnp", "hmax", "atvp", "hulu", "pcok", "ptv", "repack",
        "proper", "10bit", "8bit", "aac", "ac3", "dts", "dd5", "ddp5", "dd", "ddp", "atmos",
        "truehd", "pal", "ntsc", "dvd", "re-webrip", "yts", "rarbg",
    ]

    /// Drop everything from the first release tag, "[" or "(" onwards.
    static func cutAtReleaseTags(_ name: String) -> String {
        var out: [Substring] = []
        // Dotted release names split on dots; spaced names keep theirs ("Ep. 38").
        let separators = name.contains(" ") ? " " : " ._"
        let tokens = name.split(omittingEmptySubsequences: false, whereSeparator: { separators.contains($0) })
        for token in tokens {
            if token.hasPrefix("[") || token.hasPrefix("(") { break }
            let t = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if releaseTags.contains(t) || t.hasPrefix("ddp5") || t.hasPrefix("dd5") { break }
            out.append(token)
        }
        return out.joined(separator: separators == " " ? " " : ".")
    }

    private static func finishTitle(_ raw: String, year: Int?) -> ParsedTitle {
        ParsedTitle(title: cleanSeparators(raw), year: year, country: nil)
    }

    /// Dots and underscores become spaces unless the name already has spaces
    /// (so "Mr. Smith Goes to Washington" keeps its dot).
    static func cleanSeparators(_ raw: String) -> String {
        var s = raw
        if !s.contains(" ") || s.filter({ $0 == "." }).count > 2 {
            s = s.replacingOccurrences(of: ".", with: " ")
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–·|｜"))
    }

    private static func plausibleYear(_ y: Int) -> Bool { (1900...2100).contains(y) }

    private struct Match { var range: NSRange; var groups: [String] }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file, so a failure here is a bug.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        let ns = s as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        firstMatchWithRange(pattern, in: s)?.groups
    }

    private static func firstMatchWithRange(_ pattern: String, in s: String) -> Match? {
        let range = NSRange(location: 0, length: (s as NSString).length)
        guard let m = regex(pattern).firstMatch(in: s, range: range) else { return nil }
        return Match(range: m.range, groups: groups(m, in: s))
    }

    private static func allMatches(_ pattern: String, in s: String) -> [Match] {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex(pattern).matches(in: s, range: range).map { Match(range: $0.range, groups: groups($0, in: s)) }
    }
}
