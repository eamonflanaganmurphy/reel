import SwiftUI

struct ShowDetailView: View {
    @Bindable var show: Show

    var body: some View {
        // A scan deletes a show whose folder has gone; this page may still be open.
        if show.modelContext == nil {
            ContentUnavailableView("No Longer on the Share", systemImage: "tv",
                                   description: Text("This show's folder was removed or renamed."))
        } else {
            ShowPage(show: show)
        }
    }
}

private struct ShowPage: View {
    @Bindable var show: Show
    @Environment(PlaybackCenter.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Chosen when the page opens, then only by the user, so marking a
    /// season watched doesn't jump the page to the next one.
    @State private var season: Int?

    var body: some View {
        // Sorted once per update rather than once per use: a YouTube channel
        // can have hundreds of episodes.
        let all = show.sortedEpisodes
        let next = Show.nextUp(in: all)
        let seasons = Show.seasons(of: all)
        let selectedSeason = season ?? Self.defaultSeason(next: next, seasons: seasons)
        let episodes = all.filter { $0.season == selectedSeason }
        let layout = Sizing(sizeClass)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackdropHeader(ref: show.backdropRef ?? show.posterRef, fallbackRefs: show.fallbackRefs,
                               aspectRatio: layout.backdropAspect)

                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title).font(.title.bold())
                    HStack(spacing: 8) {
                        if let year = show.year { Text(String(year)) }
                        Text("\(seasons.filter { $0 != 0 }.count) seasons")
                        Text("\(all.count) episodes")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, -40)

                if let next {
                    Button { playback.play(next) } label: {
                        VStack(spacing: 2) {
                            Label(next.isInProgress ? "Resume" : "Play", systemImage: "play.fill").font(.headline)
                            Text("\(next.episodeCode) · \(next.title)").font(.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: layout.buttonsWidth)
                    .padding(.horizontal)
                }

                if let overview = show.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).lineLimit(5)
                        .frame(maxWidth: layout.readableWidth, alignment: .leading)
                        .padding(.horizontal)
                }

                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(seasons, id: \.self) { s in
                                Button(s == 0 ? "Specials" : "Season \(s)") { season = s }
                                    .buttonStyle(.bordered)
                                    .tint(s == selectedSeason ? .accentColor : .secondary)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                LazyVGrid(columns: layout.episodeColumns, spacing: 14) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode, thumbWidth: layout.episodeThumbWidth)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if season == nil { season = selectedSeason }
        }
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

    private static func defaultSeason(next: Video?, seasons: [Int]) -> Int {
        next?.season ?? seasons.first ?? 1
    }
}

struct EpisodeRow: View {
    @Bindable var episode: Video
    var thumbWidth: CGFloat = 150
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
                    .frame(width: thumbWidth)
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
