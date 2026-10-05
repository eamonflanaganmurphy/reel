import ReelCore
import SwiftData
import SwiftUI

/// Pieces of the movie and show pages: a big backdrop with the title over
/// it, the page tinted by the artwork, and the cast underneath.

/// The page's backdrop blurred right out behind everything, so the whole
/// page takes on the picture's colours.
struct AmbientBackground: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    var fallbackTitle: String?

    var body: some View {
        Color.black
            .overlay {
                ArtworkImage(ref: ref, fallbackRefs: fallbackRefs, fallbackTitle: fallbackTitle)
                    .blur(radius: 60, opaque: true)
                    // Dark enough for white text even over bright artwork.
                    .opacity(0.42)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The backdrop, fading into the page, with the title, details and buttons
/// over the fade. Pulling down past the top stretches it rather than
/// showing a gap above.
struct DetailHero<Content: View>: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    @ViewBuilder let content: Content

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = Sizing(sizeClass)
        ZStack(alignment: .bottomLeading) {
            ArtworkFrame(ref: ref, fallbackRefs: fallbackRefs, aspectRatio: layout.heroAspect,
                         fallbackTitle: nil, fallbackSymbol: "photo", cornerRadius: 0)
                .overlay {
                    // Keeps the status bar readable over a bright picture.
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2))
                }
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.4),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .visualEffect { image, proxy in
                    let pull = max(0, proxy.frame(in: .scrollView).minY)
                    return image.scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .bottom)
                }

            VStack(alignment: layout.isRegular ? .leading : .center, spacing: 12) {
                content
            }
            .frame(maxWidth: layout.isRegular ? 560 : .infinity, alignment: layout.isRegular ? .leading : .center)
            .multilineTextAlignment(layout.isRegular ? .leading : .center)
            .padding(.horizontal, layout.gutter)
        }
    }
}

/// The title as TMDB's logo artwork where there is one, otherwise in type.
struct TitleArt: View {
    let title: String
    let logoPath: String?

    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var logo: UIImage?

    var body: some View {
        let regular = Sizing(sizeClass).isRegular
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: regular ? 380 : 280, maxHeight: regular ? 130 : 100,
                           alignment: regular ? .leading : .center)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .accessibilityLabel(title)
                    .transition(.opacity)
            } else {
                Text(title)
                    .font(.system(regular ? .largeTitle : .title, design: .default, weight: .heavy))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
        }
        .task(id: logoPath) {
            let ref = TMDBClient.imageURL(logoPath)?.absoluteString
            let image = await ArtworkStore.shared.image(for: ref, config: settings.shareConfig)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { logo = image }
        }
    }
}

/// "2019 · 7 min · [TV-Y] · ★ 8.9", then the genres underneath.
struct MetaLines: View {
    var facts: [String]
    var certification: String?
    var rating: Double?
    var genres: [String] = []
    var watched = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: Sizing(sizeClass).isRegular ? .leading : .center, spacing: 6) {
            HStack(spacing: 8) {
                if !facts.isEmpty { Text(facts.joined(separator: " · ")) }
                if let certification {
                    Text(certification)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6), lineWidth: 1))
                }
                if let rating {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(rating, format: .number.precision(.fractionLength(1)))
                    }
                    .accessibilityLabel("Rated \(rating, format: .number.precision(.fractionLength(1))) out of 10")
                }
                if watched {
                    Image(systemName: "checkmark.circle.fill").accessibilityLabel("Watched")
                }
            }
            .lineLimit(1)
            if !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.8))
    }
}

/// A white Play button, the way the eye goes to first, with an optional
/// second line such as the episode it plays.
struct PlayButtonLabel: View {
    let title: String
    var systemImage = "play.fill"
    var detail: String?

    var body: some View {
        VStack(spacing: 1) {
            Label(title, systemImage: systemImage).font(.headline)
            if let detail { Text(detail).font(.caption).lineLimit(1).opacity(0.7) }
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
    }
}

/// The tagline, the overview (tap for the rest of a long one) and who made it.
struct AboutSection: View {
    var tagline: String?
    var overview: String?
    var credits: [(label: String, value: String)] = []

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded = false

    var body: some View {
        let hasOverview = !(overview ?? "").isEmpty
        if tagline != nil || hasOverview || !credits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let tagline {
                    Text(tagline).font(.headline).italic()
                }
                if let overview, hasOverview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(expanded ? nil : 4)
                        if overview.count > 220 {
                            Text(expanded ? "Less" : "More").font(.subheadline.weight(.semibold))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                }
                ForEach(credits, id: \.label) { credit in
                    (Text(credit.label + "  ").foregroundStyle(.white.opacity(0.6)) + Text(credit.value))
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: Sizing(sizeClass).readableWidth, alignment: .leading)
            .padding(.horizontal, Sizing(sizeClass).gutter)
        }
    }
}

/// Headshots of the cast, in billing order.
struct CastRow: View {
    let cast: [TMDBCastMember]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = Sizing(sizeClass)
        let size: CGFloat = layout.isRegular ? 100 : 78
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Cast")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: layout.isRegular ? 20 : 14) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                        // Their other titles in the library, found by TMDB's ID for them.
                        if person.id != nil {
                            NavigationLink(value: person) { CastCard(person: person, size: size) }
                                .buttonStyle(.plain)
                        } else {
                            CastCard(person: person, size: size)
                        }
                    }
                }
                .padding(.horizontal, layout.gutter)
            }
        }
    }

}

private struct CastCard: View {
    let person: TMDBCastMember
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            PersonPhoto(person: person)
                .frame(width: size)
            Text(person.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            if let character = person.character {
                Text(character)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: size + 16)
    }
}

/// A round headshot, or their initials where TMDB has no photo.
struct PersonPhoto: View {
    let person: TMDBCastMember
    var size = "w185"

    var body: some View {
        GeometryReader { geo in
            // A bigger size falls back to the cast rows' one, which scans
            // save for offline use.
            ArtworkFrame(ref: TMDBClient.imageURL(person.profilePath, size: size)?.absoluteString,
                         fallbackRefs: size == "w185" ? [] : [TMDBClient.imageURL(person.profilePath, size: "w185")?.absoluteString],
                         aspectRatio: 1, fallbackTitle: Self.initials(person.name),
                         fallbackSymbol: "person.fill", cornerRadius: geo.size.width / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

struct SectionTitle: View {
    let text: String
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.bold())
            .padding(.horizontal, Sizing(sizeClass).gutter)
    }
}

/// What a movie or show page needs of the other titles for More Like This.
protocol LibraryTitle: AnyObject {
    var persistentModelID: PersistentIdentifier { get }
    var libraryID: UUID { get }
    var tmdbID: Int? { get }
    var detailsJSON: Data? { get }
    var detailsFetchedAt: Date? { get }
}

extension Video: LibraryTitle {}
extension Show: LibraryTitle {}

/// Other titles from the library like this one: TMDB's recommendations
/// first, then ones sharing its genres. With no TMDB details to go on
/// (YouTube downloads), the rest of its own library instead.
struct MoreLikeThisRow<Title: LibraryTitle, Card: View>: View {
    let title: Title
    /// Every movie, or every show, newest first.
    let candidates: [Title]
    let libraryName: String
    @ViewBuilder let card: (Title) -> Card

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var picks: [Title] = []
    @State private var heading = "More Like This"

    var body: some View {
        Group {
            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(heading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(picks, id: \.persistentModelID) { pick in
                                card(pick).frame(width: Sizing(sizeClass).posterWidth)
                            }
                        }
                        .padding(.horizontal, Sizing(sizeClass).gutter)
                    }
                }
            }
        }
        .task(id: "\(title.detailsFetchedAt?.timeIntervalSince1970 ?? 0)/\(candidates.count)") { await pick() }
    }

    private func pick() async {
        let others = candidates.filter { $0.persistentModelID != title.persistentModelID }
        guard let target = TMDBDetails(json: title.detailsJSON) else {
            heading = "More in \(libraryName)"
            picks = Array(others.filter { $0.libraryID == title.libraryID }.prefix(15))
            return
        }
        let details = await decodeDetails(others.map(\.detailsJSON))
        let ranked = MoreLikeThis.rank(for: target, candidates: zip(others, details).map {
            MoreLikeThis.Candidate(tmdbID: $0.tmdbID, details: $1)
        })
        heading = "More Like This"
        picks = ranked.map { others[$0] }
    }
}
