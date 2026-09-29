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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = Sizing(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackdropHeader(ref: video.backdropRef ?? video.posterRef, fallbackRefs: [video.frameRef],
                               aspectRatio: layout.backdropAspect)

                HStack(alignment: .bottom, spacing: 16) {
                    ArtworkFrame(ref: video.posterRef, fallbackRefs: [video.frameRef], fallbackTitle: video.title)
                        .frame(width: layout.detailPosterWidth)
                        .shadow(radius: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.displayTitle).font(.title2.bold())
                        HStack(spacing: 8) {
                            if let year = video.year { Text(String(year)) }
                            if video.durationSeconds > 0 { Text(formatDuration(seconds: video.durationSeconds)) }
                            if video.watched { Label("Watched", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, -60)

                PlayButtons(video: video)
                    .frame(maxWidth: layout.buttonsWidth)
                    .padding(.horizontal)

                if let overview = video.overview, !overview.isEmpty {
                    Text(overview).font(.body)
                        .frame(maxWidth: layout.readableWidth, alignment: .leading)
                        .padding(.horizontal)
                }

                FileInfo(video: video)
                    .frame(maxWidth: layout.readableWidth, alignment: .leading)
                    .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { video.setWatched(!video.watched) } label: {
                    Label(video.watched ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: video.watched ? "circle" : "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
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
                    Label("Resume \(PlayerScreen.format(video.positionSeconds))", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { playback.play(video, from: 0) } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button { playback.play(video, from: 0) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
