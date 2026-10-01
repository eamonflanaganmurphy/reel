import ReelCore
import SwiftData
import SwiftUI

/// Poster grid for a collection: movies and shows from any library that its
/// filters match or that were added by hand.
struct CollectionView: View {
    let collection: CollectionConfig

    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query(filter: #Predicate<Video> { $0.isMovie }) private var movies: [Video]
    @Query private var shows: [Show]
    @State private var members: [Member] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var sort = LibraryView.SortOrder.title
    @State private var editing = false

    /// A movie or a show; collections mix them.
    enum Member: Identifiable {
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
        var addedAt: Date {
            switch self {
            case .movie(let v): v.addedAt
            case .show(let s): s.updatedAt
            }
        }
    }

    /// Changes whenever membership could: the filters, a scan adding or
    /// removing titles, or TMDB details arriving.
    private struct Inputs: Equatable {
        var collection: CollectionConfig
        var movies: Int
        var shows: Int
        var newestDetails: Date?
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Sizing(sizeClass).gridColumns, spacing: 18) {
                ForEach(sorted) { member in
                    card(member)
                        .contextMenu {
                            Button(role: .destructive) { remove(member) } label: {
                                Label("Remove from \(collection.name)", systemImage: "minus.circle")
                            }
                        }
                }
            }
            .padding()

            if loaded && members.isEmpty {
                ContentUnavailableView {
                    Label(sync.isRunning ? "Scanning…" : "Nothing in \(collection.name)", systemImage: "square.stack")
                } description: {
                    Text(collection.rules.filters.isEmpty
                         ? "Add filters to fill this collection, or add a movie or show from its page with the ••• menu."
                         : "Nothing in the library matches the filters yet. Edit them, or add a movie or show from its page with the ••• menu.")
                } actions: {
                    Button("Edit Filters") { editing = true }
                }
            }
        }
        .navigationTitle(collection.name)
        .searchable(text: $search)
        .refreshable { await sync.run(settings: settings, context: context) }
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(LibraryView.SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            Button { editing = true } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Edit Filters")
        }
        .sheet(isPresented: $editing) {
            CollectionEditor(collection: collection, onSave: settings.save, onDelete: { settings.deleteCollection(collection.id) })
        }
        .task(id: inputs) { await gather() }
        .libraryDestinations()
    }

    private var inputs: Inputs {
        let fetched = movies.lazy.compactMap(\.detailsFetchedAt).max()
        let showFetched = shows.lazy.compactMap(\.detailsFetchedAt).max()
        return Inputs(collection: collection, movies: movies.count, shows: shows.count,
                      newestDetails: [fetched, showFetched].compactMap { $0 }.max())
    }

    @ViewBuilder
    private func card(_ member: Member) -> some View {
        switch member {
        case .movie(let movie):
            NavigationLink(value: movie) {
                PosterCard(ref: movie.posterRef, fallbackRefs: [movie.frameRef], title: movie.title, subtitle: movie.year.map(String.init),
                           progress: movie.isInProgress ? movie.progress : 0, watched: movie.watched)
            }
            .buttonStyle(.plain)
        case .show(let show):
            NavigationLink(value: show) {
                PosterCard(ref: show.posterRef, fallbackRefs: show.fallbackRefs, title: show.title,
                           subtitle: show.unwatchedCount > 0 ? "\(show.unwatchedCount) unwatched" : "Watched",
                           symbol: "tv")
            }
            .buttonStyle(.plain)
        }
    }

    private var sorted: [Member] {
        let filtered = search.isEmpty ? members : members.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .title: return filtered.sorted { LibraryView.sortKey($0.title) < LibraryView.sortKey($1.title) }
        case .added: return filtered.sorted { $0.addedAt > $1.addedAt }
        case .year: return filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    /// Works out who's in. Details are decoded off the main thread, as there
    /// may be thousands.
    private func gather() async {
        let movies = movies, shows = shows, collection = collection
        let movieDetails = await decodeDetails(movies.map(\.detailsJSON))
        let showDetails = await decodeDetails(shows.map(\.detailsJSON))
        guard !Task.isCancelled else { return }
        var members: [Member] = []
        for (movie, details) in zip(movies, movieDetails)
        where movie.modelContext != nil && collection.contains(path: movie.path, candidate: movie.collectionCandidate(details: details)) {
            members.append(.movie(movie))
        }
        for (show, details) in zip(shows, showDetails)
        where show.modelContext != nil && collection.contains(path: show.path, candidate: show.collectionCandidate(details: details)) {
            members.append(.show(show))
        }
        self.members = members
        loaded = true
    }

    private func remove(_ member: Member) {
        var updated = collection
        updated.set(member.path, included: false)
        settings.save(updated)
    }
}

/// Add to / Remove from each collection, for a movie or show page's ••• menu.
struct CollectionMenuItems: View {
    let path: String
    let candidate: CollectionCandidate

    @Environment(AppSettings.self) private var settings

    var body: some View {
        if !settings.collections.isEmpty {
            Section {
                ForEach(settings.collections) { collection in
                    let included = collection.contains(path: path, candidate: candidate)
                    Button {
                        var updated = collection
                        updated.set(path, included: !included)
                        settings.save(updated)
                    } label: {
                        Label(included ? "Remove from \(collection.name)" : "Add to \(collection.name)",
                              systemImage: included ? "minus.circle" : "plus.circle")
                    }
                }
            }
        }
    }
}
