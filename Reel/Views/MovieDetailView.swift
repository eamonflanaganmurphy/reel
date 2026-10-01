import ReelCore
import SwiftData
import SwiftUI

struct MovieDetailView: View {
    @Bindable var video: Video

    var body: some View {
        // A scan deletes a movie whose file has gone; this page may still be open.
        if video.modelContext == nil {
            ContentUnavailableView("No Longer on the Share", systemImage: "film",
                                   description: Text("This file was removed or renamed."))
        } else {
            MoviePage(video: video)
        }
    }
}

private struct MoviePage: View {
    @Bindable var video: Video
    @Environment(AppSettings.self) private var settings
    @Query(filter: #Predicate<Video> { $0.isMovie }, sort: \Video.addedAt, order: .reverse) private var movies: [Video]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = Sizing(sizeClass)
        let details = video.details
        let backdrop = video.backdropRef ?? video.posterRef

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                DetailHero(ref: backdrop, fallbackRefs: [video.frameRef]) {
                    TitleArt(title: video.displayTitle, logoPath: details?.logoPath)
                    MetaLines(facts: facts(details), certification: details?.certification, rating: details?.rating,
                              genres: details?.genres ?? [], watched: video.watched)
                    PlayButtons(video: video)
                        .frame(maxWidth: layout.buttonsWidth)
                }

                AboutSection(tagline: details?.tagline, overview: video.overview, credits: credits(details))

                if let cast = details?.cast, !cast.isEmpty {
                    CastRow(cast: cast)
                }

                MoreLikeThisRow(title: video, candidates: movies, libraryName: settings.libraryName(for: video.libraryID)) { movie in
                    NavigationLink(value: movie) {
                        PosterCard(ref: movie.posterRef, fallbackRefs: [movie.frameRef], title: movie.title,
                                   subtitle: movie.year.map(String.init),
                                   progress: movie.isInProgress ? movie.progress : 0, watched: movie.watched)
                    }
                    .buttonStyle(.plain)
                }

                FileInfo(video: video)
                    .frame(maxWidth: layout.readableWidth, alignment: .leading)
                    .padding(.horizontal, layout.gutter)
            }
            .padding(.bottom, 32)
        }
        .background { AmbientBackground(ref: backdrop, fallbackRefs: [video.frameRef], fallbackTitle: video.title) }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { await DetailsLoader.load(video, settings: settings) }
        .toolbar {
            Menu {
                Button { video.setWatched(!video.watched) } label: {
                    Label(video.watched ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: video.watched ? "circle" : "checkmark.circle")
                }
                CollectionMenuItems(path: video.path, candidate: video.collectionCandidate(details: details, library: settings.libraryFolder(for: video.libraryID)))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func facts(_ details: TMDBDetails?) -> [String] {
        var facts: [String] = []
        if let year = video.year { facts.append(String(year)) }
        if let minutes = details?.runtime {
            facts.append(formatDuration(seconds: Double(minutes) * 60))
        } else if video.durationSeconds > 0 {
            facts.append(formatDuration(seconds: video.durationSeconds))
        }
        return facts
    }

    private func credits(_ details: TMDBDetails?) -> [(label: String, value: String)] {
        guard let makers = details?.makers, !makers.isEmpty else { return [] }
        return [(makers.count > 1 ? "Directors" : "Director", makers.joined(separator: ", "))]
    }
}

/// Play / Resume: resume is the big button when there's a
/// position to resume from.
struct PlayButtons: View {
    let video: Video
    @Environment(PlaybackCenter.self) private var playback

    var body: some View {
        HStack(spacing: 12) {
            if video.isInProgress {
                Button { playback.play(video) } label: {
                    PlayButtonLabel(title: "Resume \(PlayerScreen.format(video.positionSeconds))")
                }
                .buttonStyle(.borderedProminent)
                Button { playback.play(video, from: 0) } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button { playback.play(video, from: 0) } label: { PlayButtonLabel(title: "Play") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .tint(.white)
        .controlSize(.large)
    }
}

struct FileInfo: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File").font(.headline)
            Text(video.fileName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if video.fileSize > 0 {
                Text(video.fileSize.formattedFileSize).font(.caption).foregroundStyle(.secondary)
            }
            let subs = video.subtitles
            if !subs.isEmpty {
                Text("Subtitle files: " + subs.map(\.label).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
