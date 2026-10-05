import ReelCore
import SwiftData
import SwiftUI

/// A collection's movies and shows, from any library, that its filters
/// match or that were added by hand: rows by genre, or one poster grid.
struct CollectionView: View {
    let collection: CollectionConfig

    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<Video> { $0.isMovie }) private var movies: [Video]
    @Query private var shows: [Show]
    @Query(filter: #Predicate<Video> { $0.positionSeconds > 30 && !$0.watched }, sort: \Video.lastPlayedAt, order: .reverse)
    private var inProgress: [Video]
    @State private var data = BrowseData()
    @State private var search = ""
    @State private var sort = LibraryView.SortOrder.title
    @State private var editing = false
    @AppStorage private var mode: BrowseMode

    init(collection: CollectionConfig) {
        self.collection = collection
        _mode = AppStorage(wrappedValue: .browse, "browseMode." + collection.id.uuidString)
    }

    private var scope: BrowseScope { .collection(collection.id) }

    var body: some View {
        ScrollView {
            SyncBanner().padding(.top, 8)
            BrowsePage(scope: scope, data: data, all: data.entries, inProgress: data.inProgress(inProgress), mode: $mode,
                       sort: sort, search: search) { entry in
                Button(role: .destructive) { remove(entry) } label: {
                    Label("Remove from \(collection.name)", systemImage: "minus.circle")
                }
            }

            if data.loaded && data.entries.isEmpty {
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
            if data.showsGrid(mode: mode, search: search) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibraryView.SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            Button { editing = true } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Edit Filters")
        }
        .sheet(isPresented: $editing) {
            CollectionEditor(collection: collection, onSave: settings.save, onDelete: { settings.deleteCollection(collection.id) })
        }
        .task(id: BrowseData.Inputs(scope, movies: movies, shows: shows, settings: settings)) {
            if let loaded = await BrowseData.load(scope, movies: movies, shows: shows, settings: settings) { data = loaded }
        }
        .libraryDestinations()
    }

    private func remove(_ entry: LibraryEntry) {
        var updated = collection
        updated.set(entry.path, included: false)
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
