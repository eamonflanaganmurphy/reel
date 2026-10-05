import SwiftData
import SwiftUI

/// One library's movies or shows: rows by genre, or one poster grid.
struct LibraryView: View {
    let library: LibraryConfig

    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.modelContext) private var context

    @Query private var movies: [Video]
    @Query private var shows: [Show]
    @Query private var inProgress: [Video]
    @State private var search = ""
    @State private var sort = SortOrder.title
    @State private var data = BrowseData()
    /// Kept for each library, so one left on All stays on All.
    @AppStorage private var mode: BrowseMode

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case added = "Recently Added"
        case year = "Year"
    }

    init(library: LibraryConfig) {
        self.library = library
        let id = library.id
        _mode = AppStorage(wrappedValue: .browse, "browseMode." + id.uuidString)
        _movies = Query(filter: #Predicate<Video> { $0.libraryID == id && $0.isMovie }, sort: \Video.title)
        _shows = Query(filter: #Predicate<Show> { $0.libraryID == id }, sort: \Show.title)
        _inProgress = Query(filter: #Predicate<Video> { $0.libraryID == id && $0.positionSeconds > 30 && !$0.watched },
                            sort: \Video.lastPlayedAt, order: .reverse)
    }

    var body: some View {
        ScrollView {
            BrowsePage(scope: .library(library.id), data: data, all: all, inProgress: inProgress, mode: $mode,
                       sort: sort, search: search) { _ in EmptyView() }

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
            if data.showsGrid(mode: mode, search: search) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: BrowseData.Inputs(.library(library.id), movies: movies, shows: shows, settings: settings)) {
            if let loaded = await BrowseData.load(.library(library.id), movies: movies, shows: shows, settings: settings) { data = loaded }
        }
        .libraryDestinations()
    }

    private var all: [LibraryEntry] {
        library.kind == .movies ? movies.map(LibraryEntry.movie) : shows.map(LibraryEntry.show)
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
