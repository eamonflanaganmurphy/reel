import SwiftData
import SwiftUI

/// Poster grid for one library: movies, or shows.
struct LibraryView: View {
    let library: LibraryConfig

    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query private var movies: [Video]
    @Query private var shows: [Show]
    @State private var search = ""
    @State private var sort = SortOrder.title

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case added = "Recently Added"
        case year = "Year"
    }

    init(library: LibraryConfig) {
        self.library = library
        let id = library.id
        _movies = Query(filter: #Predicate<Video> { $0.libraryID == id && $0.isMovie }, sort: \Video.title)
        _shows = Query(filter: #Predicate<Show> { $0.libraryID == id }, sort: \Show.title)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Sizing(sizeClass).gridColumns, spacing: 18) {
                if library.kind == .movies {
                    ForEach(sortedMovies) { movie in
                        NavigationLink(value: movie) {
                            PosterCard(ref: movie.posterRef, fallbackRefs: [movie.frameRef], title: movie.title, subtitle: movie.year.map(String.init),
                                       progress: movie.isInProgress ? movie.progress : 0, watched: movie.watched)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(sortedShows) { show in
                        NavigationLink(value: show) {
                            PosterCard(ref: show.posterRef, fallbackRefs: show.fallbackRefs, title: show.title,
                                       subtitle: show.unwatchedCount > 0 ? "\(show.unwatchedCount) unwatched" : "Watched",
                                       symbol: "tv")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()

            if movies.isEmpty && shows.isEmpty {
                ContentUnavailableView(sync.isRunning ? "Scanning…" : "Nothing in \(library.name)",
                                       systemImage: library.systemImage,
                                       description: Text("Looking in “\(library.path)” on the share."))
            }
        }
        .navigationTitle(library.name)
        .searchable(text: $search)
        .refreshable { await sync.run(settings: settings, context: context) }
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .navigationDestination(for: Video.self) { MovieDetailView(video: $0) }
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
    }

    private var sortedMovies: [Video] {
        let filtered = search.isEmpty ? movies : movies.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .title: return filtered.sorted { Self.sortKey($0.title) < Self.sortKey($1.title) }
        case .added: return filtered.sorted { $0.addedAt > $1.addedAt }
        case .year: return filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    private var sortedShows: [Show] {
        let filtered = search.isEmpty ? shows : shows.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .title: return filtered.sorted { Self.sortKey($0.title) < Self.sortKey($1.title) }
        case .added: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .year: return filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    /// Sorts "The Office" under O.
    static func sortKey(_ title: String) -> String {
        let lower = title.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) {
            return String(lower.dropFirst(article.count))
        }
        return lower
    }
}
