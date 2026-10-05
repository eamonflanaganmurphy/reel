import ReelCore
import SwiftData
import SwiftUI

/// Someone from a cast, and everything in the library they're in. Found
/// from the cast lists the scan keeps, so it works offline; the biography
/// comes from TMDB when there's a connection.
struct PersonView: View {
    let person: TMDBCastMember

    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(filter: #Predicate<Video> { $0.isMovie }) private var movies: [Video]
    @Query private var shows: [Show]
    /// Nil while looking.
    @State private var credits: [Credit]?
    @State private var profile: TMDBPerson?
    @State private var expanded = false

    private enum Credit: Identifiable {
        case movie(Video, role: String?)
        case show(Show, role: String?)

        var id: PersistentIdentifier {
            switch self {
            case .movie(let video, _): video.persistentModelID
            case .show(let show, _): show.persistentModelID
            }
        }

        var year: Int {
            switch self {
            case .movie(let video, _): video.year ?? 0
            case .show(let show, _): show.year ?? 0
            }
        }
    }

    var body: some View {
        let layout = Sizing(sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(layout)

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("In Your Library")
                    if let credits {
                        if credits.isEmpty {
                            Text("Nothing in your library lists \(person.name) yet.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, layout.gutter)
                        } else {
                            LazyVGrid(columns: layout.gridColumns, spacing: 18) {
                                ForEach(credits) { card($0) }
                            }
                            .padding(.horizontal, layout.gutter)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background {
            AmbientBackground(ref: TMDBClient.imageURL(person.profilePath, size: "w185")?.absoluteString,
                              fallbackTitle: person.name)
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: movies.count + shows.count) { await findCredits() }
        .task { await loadProfile() }
    }

    @ViewBuilder
    private func header(_ layout: Sizing) -> some View {
        let photo = PersonPhoto(person: person, size: "h632")
            .frame(width: layout.isRegular ? 180 : 140)
            .shadow(color: .black.opacity(0.4), radius: 12)
        let text = VStack(alignment: layout.isRegular ? .leading : .center, spacing: 8) {
            Text(person.name)
                .font(.system(layout.isRegular ? .largeTitle : .title, weight: .heavy))
            if let facts = facts {
                Text(facts)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let biography = profile?.biography, !biography.isEmpty {
                VStack(alignment: layout.isRegular ? .leading : .center, spacing: 4) {
                    Text(biography)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(expanded ? nil : 5)
                    if biography.count > 300 {
                        Text(expanded ? "Less" : "More").font(.subheadline.weight(.semibold))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(layout.isRegular ? .leading : .center)

        Group {
            if layout.isRegular {
                HStack(alignment: .top, spacing: 28) {
                    photo
                    text.frame(maxWidth: layout.readableWidth, alignment: .leading)
                }
            } else {
                VStack(spacing: 16) {
                    photo
                    text
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, layout.gutter)
    }

    /// "Acting · Born 2 September 1964, Beirut, Lebanon"
    private var facts: String? {
        var parts: [String] = []
        if let department = profile?.knownForDepartment { parts.append(department) }
        if let born = Self.date(profile?.birthday) {
            var text = "Born " + born.formatted(.dateTime.day().month(.wide).year())
            if let place = profile?.placeOfBirth, !place.isEmpty { text += ", " + place }
            parts.append(text)
        }
        if let died = Self.date(profile?.deathday) {
            parts.append("Died " + died.formatted(.dateTime.day().month(.wide).year()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func card(_ credit: Credit) -> some View {
        switch credit {
        case .movie(let video, let role):
            NavigationLink(value: video) {
                PosterCard(ref: video.posterRef, fallbackRefs: [video.frameRef], title: video.title,
                           subtitle: role ?? video.year.map(String.init), watched: video.watched, download: .file(video.path))
            }
            .buttonStyle(.plain)
            .contextMenu { MovieMenuItems(movie: video) }
        case .show(let show, let role):
            NavigationLink(value: show) {
                PosterCard(ref: show.posterRef, fallbackRefs: show.fallbackRefs, title: show.title,
                           subtitle: role ?? show.year.map(String.init), symbol: "tv", download: .folder(show.path))
            }
            .buttonStyle(.plain)
        }
    }

    private func findCredits() async {
        guard let id = person.id else { credits = []; return }
        let movies = movies, shows = shows
        let movieDetails = await decodeDetails(movies.map(\.detailsJSON))
        let showDetails = await decodeDetails(shows.map(\.detailsJSON))
        var found: [Credit] = []
        for (movie, details) in zip(movies, movieDetails) {
            if let member = details?.cast.first(where: { $0.id == id }) { found.append(.movie(movie, role: member.character)) }
        }
        for (show, details) in zip(shows, showDetails) {
            if let member = details?.cast.first(where: { $0.id == id }) { found.append(.show(show, role: member.character)) }
        }
        credits = found.sorted { $0.year > $1.year }
    }

    private func loadProfile() async {
        let key = settings.tmdbKey.trimmingCharacters(in: .whitespaces)
        guard let id = person.id, !key.isEmpty, await InternetCheck.shared.isOnline() else { return }
        do {
            let loaded = try await TMDBClient(apiKey: key).person(id: id)
            withAnimation(.easeOut(duration: 0.2)) { profile = loaded }
        } catch {
            await InternetCheck.shared.noteFailure(error)
        }
    }

    /// TMDB's "1964-09-02", as a local date so it isn't a day out.
    private static func date(_ text: String?) -> Date? {
        let parts = (text ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
