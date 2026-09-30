import CryptoKit
import Foundation
import ReelCore
import SwiftUI

/// Subtitles the user added to a video from the player, kept on this phone
/// so they're there again next time it plays. Kept here rather than next to
/// the video because the nightly mirror would delete them from the share.
enum AddedSubtitles {
    private static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AddedSubtitles", isDirectory: true)
    }()

    private static func folder(for videoPath: String) -> URL {
        let digest = SHA256.hash(data: Data(videoPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    static func files(for videoPath: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(for: videoPath),
                                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return urls.filter { isSubtitle($0.lastPathComponent) }.sorted { created($0) < created($1) }
    }

    /// Copies `file` in and returns the copy. Adding a file with the same
    /// name again replaces the old one.
    static func add(_ file: URL, for videoPath: String) throws -> URL {
        let dir = folder(for: videoPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }

    static func removeAll(for videoPath: String) {
        try? FileManager.default.removeItem(at: folder(for: videoPath))
    }

    static func isSubtitle(_ name: String) -> Bool {
        MediaExtensions.subtitle.contains(NameParser.fileExtension(name))
    }

    /// "Movie.da.srt" -> "Danish", falling back to the file name.
    static func label(for file: URL, videoPath: String) -> String {
        let stem = ((videoPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return NameParser.parseSubtitle(fileName: file.lastPathComponent, videoStem: stem).label
    }
}

/// Browse the share for a subtitle file, starting in the video's own folder.
/// Back goes up a level, all the way to the top of the share.
struct ShareSubtitlePicker: View {
    let videoPath: String
    let onPick: (FileEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stack: [String]

    init(videoPath: String, onPick: @escaping (FileEntry) -> Void) {
        self.videoPath = videoPath
        self.onPick = onPick
        // "TV/Show/Season 1/x.mkv" -> ["TV", "TV/Show", "TV/Show/Season 1"]
        let parts = videoPath.split(separator: "/").dropLast()
        _stack = State(initialValue: parts.indices.map { parts[...$0].joined(separator: "/") })
    }

    var body: some View {
        NavigationStack(path: $stack) {
            SubtitleFolderList(path: "", onPick: pick, onCancel: { dismiss() })
                .navigationDestination(for: String.self) {
                    SubtitleFolderList(path: $0, onPick: pick, onCancel: { dismiss() })
                }
        }
    }

    private func pick(_ entry: FileEntry) {
        onPick(entry)
        dismiss()
    }
}

private struct SubtitleFolderList: View {
    let path: String
    let onPick: (FileEntry) -> Void
    /// Closes the sheet. This view's own dismiss would only go back a folder.
    let onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var folders: [FileEntry]?
    @State private var subtitles: [FileEntry] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let folders {
                Section {
                    if subtitles.isEmpty {
                        Text("No subtitle files in this folder.").foregroundStyle(.secondary)
                    }
                    ForEach(subtitles, id: \.path) { file in
                        Button { onPick(file) } label: {
                            Label(file.name, systemImage: "captions.bubble")
                        }
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("SRT, ASS, SSA and WebVTT files.")
                }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders, id: \.path) { folder in
                            NavigationLink(folder.name, value: folder.path)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(path.isEmpty ? settings.shareConfig.displayName : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        }
        .task {
            do {
                let entries = try await ServerConnection.shared.source(for: settings.shareConfig).list(path)
                    .filter { !$0.name.hasPrefix(".") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                subtitles = entries.filter { !$0.isDirectory && AddedSubtitles.isSubtitle($0.name) }
                folders = entries.filter(\.isDirectory)
            } catch {
                self.error = LibrarySync.describe(error)
            }
        }
    }
}
