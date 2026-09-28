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

/// 16:9 card for Keep Watching / Up Next.
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

    var body: some View {
        ArtworkFrame(ref: ref, fallbackRefs: fallbackRefs, aspectRatio: 16.0 / 9.0, fallbackTitle: nil, fallbackSymbol: "photo", cornerRadius: 0)
            .overlay {
                LinearGradient(colors: [.clear, .clear, Color(uiColor: .systemBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
    }
}

extension Int64 {
    var formattedFileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// "1 h 42 min" / "24 min"
func formatDuration(seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
}
