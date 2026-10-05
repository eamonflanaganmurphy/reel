import ReelCore
import SwiftData
import SwiftUI

/// A movie or a show, for the views that mix them.
enum LibraryEntry: Identifiable, Hashable {
    case movie(Video)
    case show(Show)

    var id: PersistentIdentifier {
        switch self {
        case .movie(let v): v.persistentModelID
        case .show(let s): s.persistentModelID
        }
    }
    var path: String {
        switch self {
        case .movie(let v): v.path
        case .show(let s): s.path
        }
    }
    var title: String {
        switch self {
        case .movie(let v): v.title
        case .show(let s): s.title
        }
    }
    var year: Int? {
        switch self {
        case .movie(let v): v.year
        case .show(let s): s.year
        }
    }
    /// A show's newest episode, so it counts as new when one arrives.
    var addedAt: Date {
        switch self {
        case .movie(let v): v.addedAt
        case .show(let s): s.updatedAt
        }
    }
    var libraryID: UUID {
        switch self {
        case .movie(let v): v.libraryID
        case .show(let s): s.libraryID
        }
    }
    var detailsJSON: Data? {
        switch self {
        case .movie(let v): v.detailsJSON
        case .show(let s): s.detailsJSON
        }
    }
    /// False once a scan has deleted it.
    var exists: Bool {
        switch self {
        case .movie(let v): v.modelContext != nil
        case .show(let s): s.modelContext != nil
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func collectionCandidate(details: TMDBDetails?, library: String) -> CollectionCandidate {
        switch self {
        case .movie(let v): v.collectionCandidate(details: details, library: library)
        case .show(let s): s.collectionCandidate(details: details, library: library)
        }
    }

    func browseItem(details: TMDBDetails?) -> BrowseItem {
        switch self {
        case .movie(let v):
            return BrowseItem(isMovie: true, title: v.title, year: v.year, addedAt: v.addedAt, details: details,
                              runtimeMinutes: v.durationSeconds > 0 ? Int(v.durationSeconds / 60) : nil,
                              watched: v.watched, started: v.watched || v.isInProgress)
        case .show(let s):
            let episodes = s.episodes
            return BrowseItem(isMovie: false, title: s.title, year: s.year, addedAt: s.updatedAt, details: details,
                              runtimeMinutes: nil, watched: !episodes.isEmpty && episodes.allSatisfy(\.watched),
                              started: episodes.contains { $0.watched || $0.isInProgress })
        }
    }

    /// The page it leads to.
    @ViewBuilder var page: some View {
        switch self {
        case .movie(let v): MovieDetailView(video: v)
        case .show(let s): ShowDetailView(show: s)
        }
    }

    /// Filtered by title and sorted, for a grid.
    static func arranged(_ entries: [LibraryEntry], by sort: LibraryView.SortOrder, search: String = "") -> [LibraryEntry] {
        let filtered = search.isEmpty ? entries : entries.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .title: return filtered.sorted { LibraryView.sortKey($0.title) < LibraryView.sortKey($1.title) }
        case .added: return filtered.sorted { $0.addedAt > $1.addedAt }
        case .year: return filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }
}

extension BrowseShelf {
    var isGenre: Bool {
        if case .genre = kind { return true }
        return false
    }
}

/// Which titles a browse page or genre page draws on.
enum BrowseScope: Hashable {
    case library(UUID)
    /// Every library of movies, or of shows.
    case kind(LibraryKind)
    case collection(UUID)
}

/// A genre's page, or several genres' together, within a scope.
struct GenreRoute: Hashable {
    var scope: BrowseScope
    var genres: [String]
}

/// Rows by genre, or one grid of everything.
enum BrowseMode: String, CaseIterable {
    case browse = "Browse"
    case all = "All"
}

/// The titles in a scope, with what browsing by genre needs of each.
struct BrowseData {
    var entries: [LibraryEntry] = []
    var items: [BrowseItem] = []
    var loaded = false

    /// Changes whenever the titles in a scope or what's known of them could:
    /// a scan adding or removing titles, TMDB details arriving, or a
    /// collection's filters changing.
    struct Inputs: Equatable {
        var scope: BrowseScope
        var collection: CollectionConfig?
        var movies: Int
        var shows: Int
        var newestDetails: Date?

        @MainActor
        init(_ scope: BrowseScope, movies: [Video], shows: [Show], settings: AppSettings) {
            self.scope = scope
            if case .collection(let id) = scope { collection = settings.collection(id) }
            self.movies = movies.count
            self.shows = shows.count
            newestDetails = [movies.lazy.compactMap(\.detailsFetchedAt).max(), shows.lazy.compactMap(\.detailsFetchedAt).max()]
                .compactMap { $0 }.max()
        }
    }

    /// Details are decoded off the main thread, as there may be thousands.
    @MainActor
    static func load(_ scope: BrowseScope, movies: [Video], shows: [Show], settings: AppSettings) async -> BrowseData? {
        var entries: [LibraryEntry]
        switch scope {
        case .library(let id):
            entries = movies.filter { $0.libraryID == id }.map(LibraryEntry.movie) + shows.filter { $0.libraryID == id }.map(LibraryEntry.show)
        case .kind(.movies): entries = movies.map(LibraryEntry.movie)
        case .kind(.shows): entries = shows.map(LibraryEntry.show)
        case .collection: entries = movies.map(LibraryEntry.movie) + shows.map(LibraryEntry.show)
        }
        let decoded = await decodeDetails(entries.map(\.detailsJSON))
        guard !Task.isCancelled else { return nil }
        var details = Array(decoded)

        if case .collection(let id) = scope {
            guard let collection = settings.collection(id) else { return nil }
            let folders = Dictionary(settings.libraries.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
            let keep = entries.indices.filter { i in
                entries[i].exists && collection.contains(path: entries[i].path, candidate: entries[i].collectionCandidate(
                    details: details[i], library: folders[entries[i].libraryID] ?? ""))
            }
            entries = keep.map { entries[$0] }
            details = keep.map { details[$0] }
        } else {
            let keep = entries.indices.filter { entries[$0].exists }
            entries = keep.map { entries[$0] }
            details = keep.map { details[$0] }
        }
        let items = zip(entries, details).map { $0.browseItem(details: $1) }
        return BrowseData(entries: entries, items: items, loaded: true)
    }

    /// Enough titles share a genre for the page to have genre rows.
    var hasGenreRows: Bool {
        GenreBrowse.counts(items).contains { $0.count >= GenreBrowse.minimumForGenreRow }
    }

    /// Whether a library's or collection's tab shows the poster grid, which
    /// is what its sort applies to. Searching is always the grid.
    func showsGrid(mode: BrowseMode, search: String) -> Bool {
        !search.isEmpty || mode == .all || (loaded && !hasGenreRows)
    }

    /// Started and unfinished videos among these titles, for Keep Watching.
    func inProgress(_ videos: [Video]) -> [Video] {
        let paths = Set(entries.map(\.path))
        return videos.filter { paths.contains($0.isMovie ? $0.path : $0.show?.path ?? "") }
    }
}

/// A movie's or show's poster, leading to its page, with its long-press
/// menu and any items the page adds to it.
struct EntryCard<Extra: View>: View {
    let entry: LibraryEntry
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        switch entry {
        case .movie(let movie):
            NavigationLink(value: movie) {
                PosterCard(ref: movie.posterRef, fallbackRefs: [movie.frameRef], title: movie.title, subtitle: movie.year.map(String.init),
                           progress: movie.isInProgress ? movie.progress : 0, watched: movie.watched)
            }
            .buttonStyle(.plain)
            .contextMenu {
                MovieMenuItems(movie: movie)
                extra()
            }
        case .show(let show):
            let link = NavigationLink(value: show) {
                PosterCard(ref: show.posterRef, fallbackRefs: show.fallbackRefs, title: show.title,
                           subtitle: show.unwatchedCount > 0 ? "\(show.unwatchedCount) unwatched" : "Watched",
                           symbol: "tv")
            }
            .buttonStyle(.plain)
            if Extra.self == EmptyView.self {
                link
            } else {
                link.contextMenu { extra() }
            }
        }
    }
}

extension EntryCard where Extra == EmptyView {
    init(entry: LibraryEntry) {
        self.init(entry: entry) { EmptyView() }
    }
}

/// Every title in one poster grid.
struct EntryGrid<Extra: View>: View {
    let entries: [LibraryEntry]
    @ViewBuilder var extra: (LibraryEntry) -> Extra

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVGrid(columns: Sizing(sizeClass).gridColumns, spacing: 18) {
            ForEach(entries) { entry in
                EntryCard(entry: entry) { extra(entry) }
            }
        }
        .padding()
    }
}

extension EntryGrid where Extra == EmptyView {
    init(entries: [LibraryEntry]) {
        self.init(entries: entries) { _ in EmptyView() }
    }
}

/// Browse or All, above a page's titles.
struct BrowseModePicker: View {
    @Binding var mode: BrowseMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(BrowseMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .padding(.horizontal)
    }
}

/// Rows of posters, as on Home. A genre's row leads to that genre's page.
struct BrowseRows<Extra: View>: View {
    let rows: [BrowseShelf]
    let data: BrowseData
    let scope: BrowseScope
    @ViewBuilder var extra: (LibraryEntry) -> Extra

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    if case .genre(let genre) = row.kind {
                        NavigationLink(value: GenreRoute(scope: scope, genres: [genre])) {
                            HStack(spacing: 6) {
                                Text(row.title).font(.title3.bold())
                                Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    } else {
                        Text(row.title).font(.title3.bold()).padding(.horizontal)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(row.indices, id: \.self) { i in
                                let entry = data.entries[i]
                                EntryCard(entry: entry) { extra(entry) }
                                    .frame(width: Sizing(sizeClass).posterWidth)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
    }
}

extension BrowseRows where Extra == EmptyView {
    init(rows: [BrowseShelf], data: BrowseData, scope: BrowseScope) {
        self.init(rows: rows, data: data, scope: scope) { _ in EmptyView() }
    }
}

/// Every genre in a scope, biggest first, each leading to its page.
struct GenreChips: View {
    let data: BrowseData
    let scope: BrowseScope

    var body: some View {
        let genres = GenreBrowse.counts(data.items)
        if !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres) { genre in
                        NavigationLink(value: GenreRoute(scope: scope, genres: [genre.genre])) {
                            ChipLabel(title: genre.genre, detail: String(genre.count), selected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// The front of a library's or collection's tab: Keep Watching, Recently
/// Added and a row per genre, or one grid of everything. Falls back to the
/// grid where there are no genres to go by, e.g. a library without TMDB.
struct BrowsePage<Extra: View>: View {
    let scope: BrowseScope
    let data: BrowseData
    /// Everything, straight from the queries, so the grid needn't wait.
    let all: [LibraryEntry]
    let inProgress: [Video]
    @Binding var mode: BrowseMode
    let sort: LibraryView.SortOrder
    let search: String
    @ViewBuilder var extra: (LibraryEntry) -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if search.isEmpty {
                if data.hasGenreRows { BrowseModePicker(mode: $mode) }
                KeepWatchingShelf(videos: inProgress)
            }
            if data.showsGrid(mode: mode, search: search) {
                EntryGrid(entries: LibraryEntry.arranged(all, by: sort, search: search), extra: extra)
            } else if data.loaded {
                GenreChips(data: data, scope: scope)
                BrowseRows(rows: GenreBrowse.libraryRows(data.items), data: data, scope: scope, extra: extra)
            } else {
                // Rows or grid isn't known until the details are in, which is quick.
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(.top)
    }
}

/// One genre, or several combined: rows of what's unwatched, best rated,
/// newest, by decade, short, and by the people in most of it; or all of it
/// in one grid. Chips combine it with the genres that most often go with it.
struct GenreView: View {
    let route: GenreRoute

    @Environment(AppSettings.self) private var settings

    @Query(filter: #Predicate<Video> { $0.isMovie }) private var movies: [Video]
    @Query private var shows: [Show]
    @Query(filter: #Predicate<Video> { $0.positionSeconds > 30 && !$0.watched }, sort: \Video.lastPlayedAt, order: .reverse)
    private var inProgress: [Video]

    @State private var data = BrowseData()
    @State private var combined: [String] = []
    @State private var mode = BrowseMode.browse
    @State private var sort = LibraryView.SortOrder.title
    @State private var surprise: LibraryEntry?
    @State private var savedName: String?

    private var genres: [String] { route.genres + combined }
    private var name: String { genres.joined(separator: " & ") }

    var body: some View {
        let matching = GenreBrowse.indices(in: genres, of: data.items)
        let subset = BrowseData(entries: matching.map { data.entries[$0] }, items: matching.map { data.items[$0] }, loaded: data.loaded)
        let hasRows = matching.count >= GenreBrowse.minimumForRows

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pairingChips
                if hasRows { BrowseModePicker(mode: $mode) }
                KeepWatchingShelf(videos: subset.inProgress(inProgress))
                if hasRows && mode == .browse {
                    BrowseRows(rows: GenreBrowse.genreRows(subset.items, indices: Array(subset.items.indices)), data: subset, scope: route.scope)
                } else {
                    EntryGrid(entries: LibraryEntry.arranged(subset.entries, by: sort))
                }
                if data.loaded && matching.isEmpty {
                    ContentUnavailableView("Nothing in \(name)", systemImage: "square.stack",
                                           description: Text("Nothing here has all of these genres."))
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(name)
        .toolbar {
            Button { surprise = pick(subset.entries, subset.items) } label: {
                Image(systemName: "shuffle")
            }
            .accessibilityLabel("Surprise Me")
            .disabled(subset.entries.isEmpty)
            let sorts = !hasRows || mode == .all
            if sorts || canSave {
                Menu {
                    if sorts {
                        Picker("Sort", selection: $sort) {
                            ForEach(LibraryView.SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if canSave {
                        Button { saveAsCollection() } label: {
                            Label("Save as Collection", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(item: $surprise) { $0.page }
        .alert("Added \(savedName ?? "")", isPresented: Binding(get: { savedName != nil }, set: { if !$0 { savedName = nil } })) {
            Button("OK") {}
        } message: {
            Text("It's a tab now, with the other collections. Edit its filters from its tab, or show and hide it in Settings → Tabs.")
        }
        .task(id: BrowseData.Inputs(route.scope, movies: movies, shows: shows, settings: settings)) {
            if let loaded = await BrowseData.load(route.scope, movies: movies, shows: shows, settings: settings) { data = loaded }
        }
    }

    /// The combined genres, on to take off, then the ones to add.
    @ViewBuilder
    private var pairingChips: some View {
        let pairings = GenreBrowse.pairings(for: genres, in: data.items)
        if !combined.isEmpty || !pairings.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(combined, id: \.self) { genre in
                        Chip(title: genre, selected: true) {
                            withAnimation { combined.removeAll { $0 == genre } }
                        }
                    }
                    ForEach(pairings, id: \.self) { genre in
                        Chip(title: "+ \(genre)", selected: false) {
                            withAnimation { combined.append(genre) }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Something not yet started, or anything if it's all been watched.
    private func pick(_ entries: [LibraryEntry], _ items: [BrowseItem]) -> LibraryEntry? {
        let fresh = entries.indices.filter { !items[$0].started && !items[$0].watched }
        return (fresh.randomElement()).map { entries[$0] } ?? entries.randomElement()
    }

    /// A collection's filters can say "these genres" and "this library",
    /// but not "in that collection".
    private var canSave: Bool {
        if case .collection = route.scope { return false }
        return true
    }

    private func saveAsCollection() {
        var filters = genres.map { CollectionFilter.genres(GenreBrowse.tmdbNames(for: $0)) }
        var contents = CollectionRules.Contents.both
        switch route.scope {
        case .library(let id):
            if let library = settings.library(id) {
                filters.append(.libraries([library.path]))
                contents = library.kind == .movies ? .movies : .shows
            }
        case .kind(let kind): contents = kind == .movies ? .movies : .shows
        case .collection: return
        }
        let collectionName = name + (contents == .movies ? " Movies" : contents == .shows ? " Shows" : "")
        settings.save(CollectionConfig(name: collectionName, rules: CollectionRules(contents: contents, match: .all, filters: filters)))
        savedName = collectionName
    }
}
