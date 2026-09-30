import SwiftUI

/// Poster with title underneath, for grids and rows.
struct PosterCard: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    let title: String
    var subtitle: String?
    var progress: Double = 0
    var watched = false
    var symbol = "film"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkFrame(ref: ref, fallbackRefs: fallbackRefs, fallbackTitle: title, fallbackSymbol: symbol)
                .overlay(alignment: .topTrailing) {
                    if watched { WatchedBadge().padding(6) }
                }
                .overlay(alignment: .bottom) {
                    if progress > 0 { ProgressBar(value: progress).padding(6) }
                }
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 16:9 card for Keep Watching.
struct WideCard: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkFrame(ref: video.backdropRef ?? video.posterRef ?? video.show?.backdropRef,
                         fallbackRefs: [video.frameRef], aspectRatio: 16.0 / 9.0, fallbackTitle: video.displayTitle,
                         fallbackSubtitle: video.isMovie ? nil : video.episodeCode, fallbackSymbol: video.isMovie ? "film" : "tv")
                .overlay(alignment: .bottom) {
                    if video.progress > 0 { ProgressBar(value: video.progress).padding(8) }
                }
            Text(video.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
            Text(video.displaySubtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.5))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 4)
    }
}

struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .font(.title3)
            .shadow(radius: 2)
    }
}

/// Videos started and not finished, most recently played first. On Home for
/// every library, and atop each library for its own. Tapping one resumes it.
struct KeepWatchingShelf: View {
    let videos: [Video]

    @Environment(PlaybackCenter.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if !videos.isEmpty {
            ShelfRow(title: "Keep Watching", items: videos, cardWidth: Sizing(sizeClass).wideCardWidth) { video in
                Button { playback.play(video) } label: { WideCard(video: video) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(video) }
            }
        }
    }

    @ViewBuilder
    private func menu(_ video: Video) -> some View {
        Button { video.setWatched(true) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        // Clears the position, which takes it off Keep Watching.
        Button { video.setWatched(false) } label: { Label("Mark as Unwatched", systemImage: "circle") }
        Button { playback.play(video, from: 0) } label: { Label("Play from Beginning", systemImage: "arrow.counterclockwise") }
    }
}

/// Horizontally scrolling titled row, as on Home.
struct ShelfRow<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    var cardWidth: CGFloat = 110
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        card(item).frame(width: cardWidth)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Backdrop that fades into the background, for detail pages.
struct BackdropHeader: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    var fallbackTitle: String?
    var aspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        ArtworkFrame(ref: ref, fallbackRefs: fallbackRefs, aspectRatio: aspectRatio, fallbackTitle: nil, fallbackSymbol: "photo", cornerRadius: 0)
            .overlay {
                LinearGradient(colors: [.clear, .clear, Color(uiColor: .systemBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
    }
}

/// Sizes for the width the app has. A regular-width window (an iPad, or
/// a big iPhone on its side) gets bigger posters, wider-cropped backdrops
/// and text kept to a readable line length.
struct Sizing {
    let isRegular: Bool

    init(_ sizeClass: UserInterfaceSizeClass?) {
        isRegular = sizeClass == .regular
    }

    var posterWidth: CGFloat { isRegular ? 150 : 110 }
    var wideCardWidth: CGFloat { isRegular ? 340 : 240 }
    var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: isRegular ? 150 : 104, maximum: isRegular ? 210 : 160), spacing: isRegular ? 20 : 14, alignment: .top)]
    }
    var detailPosterWidth: CGFloat { isRegular ? 170 : 110 }
    var episodeThumbWidth: CGFloat { isRegular ? 220 : 150 }
    /// Episodes sit two or three abreast on an iPad rather than in one long column.
    var episodeColumns: [GridItem] {
        isRegular ? [GridItem(.adaptive(minimum: 440), spacing: 24, alignment: .top)] : [GridItem(.flexible())]
    }
    /// A 16:9 backdrop across a whole iPad fills most of the screen.
    var backdropAspect: CGFloat { isRegular ? 2.4 : 16.0 / 9.0 }
    var readableWidth: CGFloat { isRegular ? 720 : .infinity }
    var buttonsWidth: CGFloat { isRegular ? 520 : .infinity }
}

extension Int64 {
    var formattedFileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// "1 h 42 min" / "24 min"
func formatDuration(seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
}
