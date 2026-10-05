import ReelCore
import SwiftData
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
    @Environment(AppSettings.self) private var settings
    @Query(sort: \Show.updatedAt, order: .reverse) private var shows: [Show]
    @Environment(PlaybackCenter.self) private var playback
    @Environment(DownloadCenter.self) private var downloads
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
        let details = show.details
        let backdrop = show.backdropRef ?? show.posterRef
        let fallbacks = show.fallbackRefs

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                DetailHero(ref: backdrop, fallbackRefs: fallbacks) {
                    TitleArt(title: show.title, logoPath: details?.logoPath)
                    MetaLines(facts: facts(details, seasons: seasons, episodes: all.count),
                              certification: details?.certification, rating: details?.rating, genres: details?.genres ?? [])
                    if let next {
                        Button { playback.play(next) } label: {
                            PlayButtonLabel(title: next.isInProgress ? "Resume" : "Play",
                                            detail: next.isMovie ? nil : "\(next.episodeCode) · \(next.title)")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .controlSize(.large)
                        .frame(maxWidth: layout.buttonsWidth)
                    }
                }

                AboutSection(tagline: details?.tagline, overview: show.overview, credits: credits(details))

                VStack(alignment: .leading, spacing: 14) {
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons, id: \.self) { s in
                                    SeasonChip(title: s == 0 ? "Specials" : "Season \(s)", selected: s == selectedSeason) {
                                        withAnimation(.easeInOut(duration: 0.2)) { season = s }
                                    }
                                }
                            }
                            .padding(.horizontal, layout.gutter)
                        }
                    } else {
                        SectionTitle("Episodes")
                    }

                    LazyVGrid(columns: layout.episodeColumns, spacing: 12) {
                        ForEach(episodes) { episode in
                            EpisodeRow(episode: episode, thumbWidth: layout.episodeThumbWidth)
                        }
                    }
                    .padding(.horizontal, layout.gutter)
                }

                if let cast = details?.cast, !cast.isEmpty {
                    CastRow(cast: cast)
                }

                MoreLikeThisRow(title: show, candidates: shows, libraryName: settings.libraryName(for: show.libraryID)) { other in
                    NavigationLink(value: other) {
                        PosterCard(ref: other.posterRef, fallbackRefs: other.fallbackRefs, title: other.title,
                                   subtitle: other.year.map(String.init), symbol: "tv")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 32)
        }
        .background { AmbientBackground(ref: backdrop, fallbackRefs: fallbacks, fallbackTitle: show.title) }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if season == nil { season = selectedSeason }
        }
        .task { await DetailsLoader.load(show, settings: settings) }
        .toolbar {
            Menu {
                Button {
                    episodes.forEach { $0.setWatched(true) }
                } label: { Label("Mark Season as Watched", systemImage: "checkmark.circle") }
                Button {
                    episodes.forEach { $0.setWatched(false) }
                } label: { Label("Mark Season as Unwatched", systemImage: "circle") }
                CollectionMenuItems(path: show.path, candidate: show.collectionCandidate(details: details, library: settings.libraryFolder(for: show.libraryID)))
                Section {
                    if episodes.contains(where: { downloads.state(of: $0.path) == .notDownloaded }) {
                        Button { downloads.download(episodes) } label: {
                            Label("Download Season", systemImage: "arrow.down.circle")
                        }
                    }
                    if episodes.contains(where: { downloads.state(of: $0.path) != .notDownloaded }) {
                        Button(role: .destructive) { downloads.remove(episodes.map(\.path)) } label: {
                            Label("Remove Season Downloads", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func facts(_ details: TMDBDetails?, seasons: [Int], episodes: Int) -> [String] {
        var facts: [String] = []
        if let year = show.year { facts.append(String(year)) }
        let real = seasons.filter { $0 != 0 }.count
        if real > 1 {
            facts.append("\(real) seasons")
        } else {
            facts.append(episodes == 1 ? "1 episode" : "\(episodes) episodes")
        }
        if let minutes = details?.runtime { facts.append("\(minutes) min") }
        return facts
    }

    private func credits(_ details: TMDBDetails?) -> [(label: String, value: String)] {
        var credits: [(label: String, value: String)] = []
        if let makers = details?.makers, !makers.isEmpty { credits.append(("Created by", makers.joined(separator: ", "))) }
        if let network = details?.network { credits.append(("Network", network)) }
        return credits
    }

    private static func defaultSeason(next: Video?, seasons: [Int]) -> Int {
        next?.season ?? seasons.first ?? 1
    }
}

private struct SeasonChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.black : Color.primary)
                .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    HStack(spacing: 6) {
                        if let minutes = episode.runtimeMinutes {
                            Text("\(minutes) min").foregroundStyle(.tertiary)
                        }
                        DownloadBadge(path: episode.path)
                    }
                    .font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            WatchedMenuItems(video: episode)
            if episode.isInProgress {
                Button { playback.play(episode, from: 0) } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
            Button { expanded.toggle() } label: { Label(expanded ? "Less" : "More", systemImage: "text.alignleft") }
            Section { DownloadMenuItems(video: episode) }
        }
    }
}
