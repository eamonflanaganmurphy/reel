import SwiftData
import SwiftUI

struct HomeView: View {
    var openSettings: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(PlaybackCenter.self) private var playback
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<Video> { $0.positionSeconds > 30 && !$0.watched },
           sort: \Video.lastPlayedAt, order: .reverse)
    private var inProgress: [Video]

    @Query(filter: #Predicate<Video> { $0.isMovie }, sort: \Video.addedAt, order: .reverse)
    private var movies: [Video]

    @Query(sort: \Show.updatedAt, order: .reverse)
    private var shows: [Show]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                statusBanner

                if !inProgress.isEmpty {
                    ShelfRow(title: "Keep Watching", items: inProgress, cardWidth: 240) { video in
                        Button { playback.play(video) } label: { WideCard(video: video) }
                            .buttonStyle(.plain)
                            .contextMenu { keepWatchingMenu(video) }
                    }
                }

                ForEach(settings.libraries) { library in
                    libraryShelf(library)
                }

                if movies.isEmpty && shows.isEmpty && !sync.isRunning {
                    emptyState
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Reel")
        .refreshable { await sync.run(settings: settings, context: context) }
        .navigationDestination(for: Video.self) { MovieDetailView(video: $0) }
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
    }

    @ViewBuilder
    private func libraryShelf(_ library: LibraryConfig) -> some View {
        switch library.kind {
        case .movies:
            let recent = Array(movies.filter { $0.libraryID == library.id }.prefix(20))
            if !recent.isEmpty {
                ShelfRow(title: "Recently Added · \(library.name)", items: recent) { movie in
                    NavigationLink(value: movie) {
                        PosterCard(ref: movie.posterRef, fallbackRefs: [movie.frameRef], title: movie.title, subtitle: movie.year.map(String.init),
                                   progress: movie.isInProgress ? movie.progress : 0, watched: movie.watched)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .shows:
            let recent = Array(shows.filter { $0.libraryID == library.id }.prefix(20))
            if !recent.isEmpty {
                ShelfRow(title: "Recently Updated · \(library.name)", items: recent) { show in
                    NavigationLink(value: show) {
                        PosterCard(ref: show.posterRef, fallbackRefs: show.fallbackRefs, title: show.title,
                                   subtitle: "\(show.episodes.count) episodes", symbol: "tv")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch sync.state {
        case .scanning(let message):
            HStack(spacing: 10) {
                ProgressView()
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(.horizontal)
        case .idle:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(settings.isConfigured ? "Nothing here yet" : "Connect to your share").font(.title3.bold())
            Text(settings.isConfigured
                 ? "Pull down to scan the share, or check the library folders in Settings."
                 : "Add the router's address, share name and login in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(settings.isConfigured ? "Scan Now" : "Open Settings") {
                if settings.isConfigured {
                    Task { await sync.run(settings: settings, context: context) }
                } else {
                    openSettings()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func keepWatchingMenu(_ video: Video) -> some View {
        Button { video.setWatched(true) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        // Clears the position, which takes it off Keep Watching.
        Button { video.setWatched(false) } label: { Label("Mark as Unwatched", systemImage: "circle") }
        Button { playback.play(video, from: 0) } label: { Label("Play from Beginning", systemImage: "arrow.counterclockwise") }
    }
}
