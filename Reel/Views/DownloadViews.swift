import ReelCore
import SwiftData
import SwiftUI

/// The download button beside Play on a movie page: tap to download, then
/// a ring while it comes in, and a menu to remove it once it's here.
struct DownloadButton: View {
    let video: Video
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        let state = downloads.state(of: video.path)
        Group {
            switch state {
            case .notDownloaded:
                Button { downloads.download([video]) } label: { icon("arrow.down.circle") }
                    .accessibilityLabel("Download")
            case .failed:
                Menu {
                    DownloadMenuItems(video: video)
                } label: {
                    icon("exclamationmark.arrow.circlepath")
                }
                .accessibilityLabel("Download Failed")
            default:
                Menu {
                    DownloadMenuItems(video: video)
                } label: {
                    Group {
                        if state == .downloaded {
                            icon("checkmark.circle.fill")
                        } else {
                            DownloadProgressRing(state: state).frame(width: 22, height: 22).frame(width: 28)
                        }
                    }
                }
                .accessibilityLabel(state == .downloaded ? "Downloaded" : "Downloading")
            }
        }
        .buttonStyle(.bordered)
        .menuStyle(.button)
        .fixedSize()
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.headline).frame(width: 28)
    }
}

/// Download, cancel or remove one video, for its menus.
struct DownloadMenuItems: View {
    let video: Video
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        switch downloads.state(of: video.path) {
        case .notDownloaded:
            Button { downloads.download([video]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        case .failed(let message):
            Section(message) {
                Button { downloads.retry(video.path) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { downloads.remove([video.path]) } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }
        case .queued, .downloading:
            Button(role: .destructive) { downloads.remove([video.path]) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .downloaded:
            // Save to Files, AirDrop and the like.
            if let file = downloads.localURL(for: video.path) {
                ShareLink(item: file) { Label("Share File…", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { downloads.remove([video.path]) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }
}

/// How far a download has got, as a ring with a stop square in it, like
/// the App Store's. Empty while it waits its turn.
struct DownloadProgressRing: View {
    let state: DownloadCenter.State

    private var fraction: Double {
        if case .downloading(let f) = state { return f ?? 0 }
        return 0
    }

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.4), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: fraction)
            RoundedRectangle(cornerRadius: 1.5).frame(width: 7, height: 7)
        }
    }
}

/// A small mark on an episode for where its download is at, or nothing.
struct DownloadBadge: View {
    let path: String
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        switch downloads.state(of: path) {
        case .notDownloaded:
            EmptyView()
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        case let state:
            DownloadProgressRing(state: state).frame(width: 13, height: 13)
                .accessibilityLabel("Downloading")
        }
    }
}

/// Everything downloaded or on the way, from Home.
struct DownloadsView: View {
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        DownloadList(paths: downloads.items.map(\.path))
            .navigationTitle("Downloads")
    }
}

private struct DownloadList: View {
    @Environment(DownloadCenter.self) private var downloads
    @Query private var videos: [Video]
    @State private var confirmingRemoveAll = false

    init(paths: [String]) {
        _videos = Query(filter: #Predicate<Video> { paths.contains($0.path) })
    }

    var body: some View {
        let byPath = Dictionary(videos.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let pending = downloads.items.filter { !$0.finished }
        // Shows together and their episodes in order, movies by title.
        let finished = downloads.items.filter(\.finished).sorted { a, b in
            guard let x = byPath[a.path], let y = byPath[b.path] else { return a.path < b.path }
            return (x.displayTitle, x.season, x.episode ?? .max, x.path) < (y.displayTitle, y.season, y.episode ?? .max, y.path)
        }

        List {
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { item in
                        DownloadRow(item: item, video: byPath[item.path])
                    }
                    .onDelete { offsets in downloads.remove(offsets.map { pending[$0].path }) }
                } header: {
                    Text("Downloading")
                } footer: {
                    if let reason = downloads.stopReason {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(reason).foregroundStyle(.orange)
                            Button("Try Again") { downloads.resume() }.font(.footnote.weight(.semibold))
                        }
                    } else if downloads.paused {
                        Text("Waiting while the share is scanned.")
                    } else {
                        Text("Keep Reel open until these finish: iOS only lets a download carry on for a few minutes once the app is put away. It picks up where it left off next time.")
                    }
                }
            }
            if !finished.isEmpty {
                Section {
                    ForEach(finished) { item in
                        DownloadRow(item: item, video: byPath[item.path])
                    }
                    .onDelete { offsets in downloads.remove(offsets.map { finished[$0].path }) }
                } header: {
                    Text("On This Device")
                } footer: {
                    Text(storageSummary)
                }
            }
        }
        .overlay {
            if downloads.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download movies and episodes from their pages to watch them away from the share."))
            }
        }
        .toolbar {
            if !downloads.items.isEmpty {
                Menu {
                    Button(role: .destructive) { confirmingRemoveAll = true } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Remove all downloads from this device?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They stay on the share.")
        }
    }

    private var storageSummary: String {
        var summary = "\(downloads.bytesOnDevice.formattedFileSize) on this device"
        if let free = DownloadCenter.freeSpace { summary += ", \(free.formattedFileSize) free" }
        return summary + ". Downloads play without the share, and watch progress syncs next time it's in reach."
    }
}

private struct DownloadRow: View {
    let item: DownloadCenter.Item
    let video: Video?

    @Environment(DownloadCenter.self) private var downloads
    @Environment(PlaybackCenter.self) private var playback

    var body: some View {
        let state = downloads.state(of: item.path)
        Button {
            switch state {
            case .downloaded: if let video { playback.play(video) }
            case .failed: downloads.retry(item.path)
            default: break
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkFrame(ref: video.flatMap { $0.isMovie ? ($0.backdropRef ?? $0.posterRef) : ($0.posterRef ?? $0.show?.backdropRef) },
                             fallbackRefs: [video?.frameRef], aspectRatio: 16.0 / 9.0,
                             fallbackTitle: video?.displayTitle ?? item.fileName,
                             fallbackSubtitle: video.flatMap { $0.isMovie ? nil : Optional($0.episodeCode) },
                             fallbackSymbol: video?.isMovie == false ? "tv" : "film", cornerRadius: 6)
                    .frame(width: 100)
                    .overlay(alignment: .bottom) {
                        if let video, video.isInProgress { ProgressBar(value: video.progress).padding(4) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video?.displayTitle ?? item.fileName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let subtitle = video?.displaySubtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status(state)
                }
                Spacer(minLength: 0)
                if state == .downloaded {
                    Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let video { DownloadMenuItems(video: video) }
        }
    }

    @ViewBuilder
    private func status(_ state: DownloadCenter.State) -> some View {
        switch state {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction ?? 0)
                let bytes = downloads.bytesReceived(item.path)
                Text(item.size > 0
                     ? "\(bytes.formattedFileSize) of \(item.size.formattedFileSize)"
                     : bytes.formattedFileSize)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .queued:
            Text(item.size > 0 ? "Waiting · \(item.size.formattedFileSize)" : "Waiting")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message + " Tap to try again.").font(.caption2).foregroundStyle(.orange).lineLimit(3)
        case .downloaded:
            Text(item.size.formattedFileSize).font(.caption2).foregroundStyle(.secondary)
        case .notDownloaded:
            EmptyView()
        }
    }
}
