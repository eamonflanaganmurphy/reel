import SwiftUI

struct ShowDetailView: View {
    @Bindable var show: Show
    @Environment(PlaybackCenter.self) private var playback
    @State private var season: Int?

    private var selectedSeason: Int { season ?? show.nextUp?.season ?? show.seasons.first ?? 1 }
    private var episodes: [Video] { show.sortedEpisodes.filter { $0.season == selectedSeason } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackdropHeader(ref: show.backdropRef ?? show.posterRef, fallbackRefs: show.fallbackRefs)

                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title).font(.title.bold())
                    HStack(spacing: 8) {
                        if let year = show.year { Text(String(year)) }
                        Text("\(show.seasons.filter { $0 != 0 }.count) seasons")
                        Text("\(show.episodes.count) episodes")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, -40)

                if let next = show.nextUp {
                    Button { playback.play(next) } label: {
                        VStack(spacing: 2) {
                            Label(next.isInProgress ? "Resume" : "Play", systemImage: "play.fill").font(.headline)
                            Text("\(next.episodeCode) · \(next.title)").font(.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                }

                if let overview = show.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).lineLimit(5).padding(.horizontal)
                }

                if show.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(show.seasons, id: \.self) { s in
                                Button(s == 0 ? "Specials" : "Season \(s)") { season = s }
                                    .buttonStyle(.bordered)
                                    .tint(s == selectedSeason ? .accentColor : .secondary)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                LazyVStack(spacing: 14) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button {
                    episodes.forEach { $0.setWatched(true) }
                } label: { Label("Mark Season as Watched", systemImage: "checkmark.circle") }
                Button {
                    episodes.forEach { $0.setWatched(false) }
                } label: { Label("Mark Season as Unwatched", systemImage: "circle") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

struct EpisodeRow: View {
    @Bindable var episode: Video
    @Environment(PlaybackCenter.self) private var playback
    @State private var expanded = false

    var body: some View {
        Button { playback.play(episode) } label: {
            HStack(alignment: .top, spacing: 12) {
                // No still: a frame from the file, then the show's backdrop,
                // then a generated card.
                ArtworkFrame(ref: episode.posterRef, fallbackRefs: [episode.frameRef, episode.show?.backdropRef],
                             aspectRatio: 16.0 / 9.0, fallbackTitle: episode.show?.title, fallbackSubtitle: episode.episodeCode,
                             fallbackSymbol: "play.rectangle", cornerRadius: 6)
                    .frame(width: 150)
                    .overlay(alignment: .bottom) {
                        if episode.isInProgress { ProgressBar(value: episode.progress).padding(5) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if episode.watched { WatchedBadge().font(.body).padding(4) }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.episode.map { n in episode.episodeEnd.map { "\(n)–\($0)" } ?? "\(n)" } ?? "Special")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3)
                    }
                    if let minutes = episode.runtimeMinutes {
                        Text("\(minutes) min").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { episode.setWatched(!episode.watched) } label: {
                Label(episode.watched ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: episode.watched ? "circle" : "checkmark.circle")
            }
            if episode.isInProgress {
                Button { playback.play(episode, from: 0) } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
            Button { expanded.toggle() } label: { Label(expanded ? "Less" : "More", systemImage: "text.alignleft") }
        }
    }
}
