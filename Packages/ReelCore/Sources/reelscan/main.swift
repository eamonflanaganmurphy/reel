import Foundation
import ReelCore

// Runs the app's scanner against a real share from a terminal, so the SMB
// settings and the parser can be checked without building the iOS app:
//
//   swift run reelscan --host 192.168.8.1 --share media --user me --password pw \
//       --movies movies --shows TV --shows childrens-shows
//
// Add --all to print every item instead of a summary.

var args = Array(CommandLine.arguments.dropFirst())
var host = "", share = "", user = "", password = ""
var libraries: [(String, LibraryKind)] = []
var printAll = false

while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fatalError("\(flag) needs a value") }
        return args.removeFirst()
    }
    switch flag {
    case "--host": host = value()
    case "--share": share = value()
    case "--user": user = value()
    case "--password": password = value()
    case "--movies": libraries.append((value(), .movies))
    case "--shows": libraries.append((value(), .shows))
    case "--all": printAll = true
    default: fatalError("unknown flag \(flag)")
    }
}

guard !host.isEmpty, !share.isEmpty, !libraries.isEmpty else {
    print("usage: reelscan --host H --share S [--user U --password P] (--movies PATH | --shows PATH)... [--all]")
    exit(2)
}

let config = SMBConfig(host: host, share: share, username: user, password: password)
let source = try SMBFileSource(config: config)
let scanner = LibraryScanner(source: source)

for (path, kind) in libraries {
    let start = Date()
    let result = try await scanner.scan(root: path, kind: kind)
    let secs = String(format: "%.1f", Date().timeIntervalSince(start))
    switch kind {
    case .movies:
        print("== \(path): \(result.movies.count) movies in \(secs)s")
        let noYear = result.movies.filter { $0.year == nil }
        for m in printAll ? result.movies : noYear {
            print("  \(m.title) (\(m.year.map(String.init) ?? "no year")) subs=\(m.video.subtitles.count)  <- \(m.video.path)")
        }
    case .shows:
        let eps = result.shows.reduce(0) { $0 + $1.episodes.count }
        print("== \(path): \(result.shows.count) shows, \(eps) episodes in \(secs)s")
        for s in result.shows {
            let loose = s.episodes.filter { $0.episode == nil }
            print("  \(s.title)\(s.year.map { " (\($0))" } ?? "")\(s.country.map { " [\($0)]" } ?? ""): \(s.episodes.count) eps, \(loose.count) without SxxEyy")
            for e in printAll ? s.episodes : loose {
                let code = e.episode.map { String(format: "S%02dE%02d", e.season, $0) } ?? "S\(e.season)E?"
                print("    \(code) \(e.title ?? "-") subs=\(e.video.subtitles.map(\.label))")
            }
        }
    }
}
await source.disconnect()
