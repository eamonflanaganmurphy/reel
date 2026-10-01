import ReelCore
import SwiftData
import SwiftUI

/// A collection's name and filters, and the titles put in or taken out by hand.
struct CollectionEditor: View {
    @State var collection: CollectionConfig
    let onSave: (CollectionConfig) -> Void
    var onDelete: (() -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Video> { $0.isMovie }) private var movies: [Video]
    @Query private var shows: [Show]
    @State private var path: [Int] = []
    @State private var confirmingDelete = false
    @State private var found = FoundValues()

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                TextField("Name", text: $collection.name, prompt: Text("Kids & Family"))

                Section {
                    Picker("Contains", selection: $collection.rules.contents) {
                        Text("Movies & Shows").tag(CollectionRules.Contents.both)
                        Text("Movies").tag(CollectionRules.Contents.movies)
                        Text("Shows").tag(CollectionRules.Contents.shows)
                    }
                    if collection.rules.filters.filter({ !$0.isExclusion }).count > 1 {
                        Picker("Include Titles That Match", selection: $collection.rules.match) {
                            Text("Any Filter").tag(CollectionRules.Match.any)
                            Text("All Filters").tag(CollectionRules.Match.all)
                        }
                    }
                    ForEach(collection.rules.filters.indices, id: \.self) { i in
                        NavigationLink(value: i) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.rules.filters[i].kind.name)
                                Text(summary(collection.rules.filters[i]))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .onDelete { collection.rules.filters.remove(atOffsets: $0) }
                    Menu {
                        ForEach(FilterKind.allCases, id: \.self) { kind in
                            Button(kind.name) {
                                collection.rules.filters.append(kind.empty)
                                path.append(collection.rules.filters.count - 1)
                            }
                        }
                    } label: {
                        Label("Add Filter", systemImage: "plus")
                    }
                } header: {
                    Text("Filters")
                } footer: {
                    Text(filtersFooter)
                }

                handPicked("Added by Hand", paths: collection.picked(true),
                           footer: "In the collection whatever the filters say. Swipe to let the filters decide again.") {
                    collection.set($0, included: nil)
                }
                handPicked("Removed by Hand", paths: collection.picked(false),
                           footer: "Kept out whatever the filters say. Swipe to let the filters decide again.") {
                    collection.set($0, included: nil)
                }

                if let onDelete {
                    Section {
                        Button("Delete Collection", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete “\(collection.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                Button("Delete Collection", role: .destructive) {
                                    onDelete()
                                    dismiss()
                                }
                            } message: {
                                Text("Only the collection goes; the movies and shows stay in their libraries.")
                            }
                    }
                }
            }
            .navigationDestination(for: Int.self) { i in
                if collection.rules.filters.indices.contains(i) {
                    FilterEditor(filter: $collection.rules.filters[i], found: found)
                }
            }
            .navigationTitle(collection.name.isEmpty ? "New Collection" : collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = collection
                        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                        saved.rules.filters.removeAll(where: \.isEmpty)
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(collection.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await findValues() }
        }
    }

    private var filtersFooter: String {
        let filters = collection.rules.filters
        if filters.isEmpty { return "With no filters, the collection holds only what you add by hand from a movie or show's ••• menu." }
        var lines: [String] = []
        if filters.contains(where: \.isExclusion) { lines.append("“Not in Genre” always applies.") }
        if filters.filter({ !$0.isExclusion }).count > 1 {
            lines.append(collection.rules.match == .any
                ? "A title joins if it matches any of the other filters."
                : "A title joins only if it matches all of the other filters.")
        }
        lines.append("Titles without TMDB details have no rating or genre, so add them by hand or with a Library filter.")
        return lines.joined(separator: " ")
    }

    @ViewBuilder
    private func handPicked(_ title: String, paths: [String], footer: String, remove: @escaping (String) -> Void) -> some View {
        if !paths.isEmpty {
            let names = titlesByPath
            let rows = paths.sorted { (names[$0] ?? $0) < (names[$1] ?? $1) }
            Section {
                ForEach(rows, id: \.self) { path in
                    if let name = names[path] {
                        Text(name)
                    } else {
                        // Renamed or deleted on the share since.
                        LabeledContent((path as NSString).lastPathComponent, value: "Not on the share")
                    }
                }
                .onDelete { offsets in offsets.map { rows[$0] }.forEach(remove) }
            } header: {
                Text(title)
            } footer: {
                Text(footer)
            }
        }
    }

    private var titlesByPath: [String: String] {
        var names: [String: String] = [:]
        for movie in movies { names[movie.path] = movie.year.map { "\(movie.title) (\($0))" } ?? movie.title }
        for show in shows { names[show.path] = show.title }
        return names
    }

    private func findValues() async {
        let details = await decodeDetails(movies.map(\.detailsJSON) + shows.map(\.detailsJSON))
        found.ratings = FilterEditor.ordered(ratings: Set(details.compactMap { $0?.certification }.filter { !$0.isEmpty }))
        found.genres = Set(details.flatMap { $0?.genres ?? [] }).sorted()
        found.loaded = true
    }

    private func summary(_ filter: CollectionFilter) -> String {
        switch filter {
        case .libraries(let folders):
            return folders.isEmpty ? "None chosen" : FilterEditor.libraryNames(folders, in: settings.libraries).joined(separator: ", ")
        case .ageRatings(let set):
            return set.isEmpty ? "None chosen" : FilterEditor.ordered(ratings: set).joined(separator: ", ")
        case .genres(let set):
            return set.isEmpty ? "None chosen" : set.sorted().joined(separator: " or ")
        case .notGenres(let set):
            return set.isEmpty ? "None chosen" : "Not " + set.sorted().joined(separator: ", ")
        case .years(let from, let to):
            switch (from, to) {
            case let (from?, to?): return "\(from)–\(to)"
            case let (from?, nil): return "\(from) or later"
            case let (nil, to?): return "\(to) or earlier"
            case (nil, nil): return "Any year"
            }
        case .minimumRating(let rating):
            return "★ \(rating.formatted(.number.precision(.fractionLength(1)))) or higher"
        case .maximumRuntime(let minutes):
            return formatDuration(seconds: Double(minutes) * 60) + " or shorter"
        }
    }
}

/// Every age rating and genre in the library, to pick from. A class, so a
/// filter page already open fills in when they arrive.
@Observable
final class FoundValues {
    var ratings: [String] = []
    var genres: [String] = []
    var loaded = false
}

/// The sorts of filter there are, for Add Filter and headings.
enum FilterKind: CaseIterable {
    case libraries, ageRatings, genres, notGenres, years, minimumRating, maximumRuntime

    var name: String {
        switch self {
        case .libraries: "Library"
        case .ageRatings: "Age Rating"
        case .genres: "Genre"
        case .notGenres: "Not in Genre"
        case .years: "Year"
        case .minimumRating: "TMDB Rating"
        case .maximumRuntime: "Length"
        }
    }

    var empty: CollectionFilter {
        switch self {
        case .libraries: .libraries([])
        case .ageRatings: .ageRatings([])
        case .genres: .genres([])
        case .notGenres: .notGenres([])
        case .years: .years(from: nil, to: nil)
        case .minimumRating: .minimumRating(7)
        case .maximumRuntime: .maximumRuntime(100)
        }
    }
}

extension CollectionFilter {
    var kind: FilterKind {
        switch self {
        case .libraries: .libraries
        case .ageRatings: .ageRatings
        case .genres: .genres
        case .notGenres: .notGenres
        case .years: .years
        case .minimumRating: .minimumRating
        case .maximumRuntime: .maximumRuntime
        }
    }

    /// Nothing chosen, so it would do nothing, or shut everything out.
    var isEmpty: Bool {
        switch self {
        case .libraries(let s): s.isEmpty
        case .ageRatings(let s), .genres(let s), .notGenres(let s): s.isEmpty
        case .years(let from, let to): from == nil && to == nil
        case .minimumRating, .maximumRuntime: false
        }
    }
}

/// One filter's values.
///
/// Works on its own copy, written back on each change: a page pushed with
/// `navigationDestination` isn't redrawn when the editor's state changes,
/// so reading the filter through the binding left taps unseen.
struct FilterEditor: View {
    @Binding var filter: CollectionFilter
    let found: FoundValues

    @Environment(AppSettings.self) private var settings
    @State private var draft: CollectionFilter
    @State private var newRating = ""

    init(filter: Binding<CollectionFilter>, found: FoundValues) {
        _filter = filter
        self.found = found
        _draft = State(initialValue: filter.wrappedValue)
    }

    var body: some View {
        Form {
            switch draft {
            case .libraries(let folders):
                Section {
                    ForEach(settings.libraries) { library in
                        checkRow(library.name, systemImage: library.systemImage, on: folders.contains(library.path)) {
                            draft = .libraries(folders.toggling(library.path))
                        }
                    }
                    // Chosen on another phone, which has libraries this one doesn't.
                    ForEach(folders.subtracting(settings.libraries.map(\.path)).sorted(), id: \.self) { folder in
                        checkRow(folder, systemImage: "folder", on: true) { draft = .libraries(folders.toggling(folder)) }
                    }
                } footer: {
                    Text("Everything in these libraries joins, with or without TMDB details. Libraries go by their folder in the share, so the filter works on every phone.")
                }
            case .ageRatings(let ratings):
                Section {
                    ForEach(Self.ordered(ratings: ratings.union(found.ratings)), id: \.self) { rating in
                        checkRow(rating, on: ratings.contains(rating)) { draft = .ageRatings(ratings.toggling(rating)) }
                    }
                    HStack {
                        TextField("Another rating, e.g. 12A", text: $newRating)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onSubmit(addRating)
                        Button("Add", action: addRating).disabled(newRating.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("The ratings TMDB gives the titles in your library. Titles without one don't match.")
                }
            case .genres(let genres):
                genreList(genres, footer: "Titles in any of these genres join.") { draft = .genres($0) }
            case .notGenres(let genres):
                genreList(genres, footer: "Titles in any of these genres are kept out, however the other filters combine.") {
                    draft = .notGenres($0)
                }
            case .years(let from, let to):
                Section {
                    yearField("From", value: from) { draft = .years(from: $0, to: to) }
                    yearField("To", value: to) { draft = .years(from: from, to: $0) }
                } footer: {
                    Text("Leave either empty for no limit that way.")
                }
            case .minimumRating(let rating):
                Section {
                    Stepper(value: Binding(get: { rating }, set: { draft = .minimumRating($0) }), in: 0...10, step: 0.5) {
                        Text("★ \(rating.formatted(.number.precision(.fractionLength(1)))) or higher")
                    }
                } footer: {
                    Text("TMDB's score out of 10. Titles too few people have rated don't match.")
                }
            case .maximumRuntime(let minutes):
                Section {
                    Stepper(value: Binding(get: { minutes }, set: { draft = .maximumRuntime($0) }), in: 10...300, step: 5) {
                        Text(formatDuration(seconds: Double(minutes) * 60) + " or shorter")
                    }
                } footer: {
                    Text("A movie's length, or a show's typical episode.")
                }
            }
        }
        .navigationTitle(draft.kind.name)
        .onChange(of: draft) { _, new in filter = new }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRating() {
        let rating = newRating.trimmingCharacters(in: .whitespaces).uppercased()
        guard !rating.isEmpty, case .ageRatings(let ratings) = draft else { return }
        draft = .ageRatings(ratings.union([rating]))
        newRating = ""
    }

    private func genreList(_ genres: Set<String>, footer: String, set: @escaping (Set<String>) -> Void) -> some View {
        Section {
            if !found.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if found.genres.isEmpty && genres.isEmpty {
                Text("No genres yet. They come from TMDB during a scan.").foregroundStyle(.secondary)
            }
            ForEach(genres.union(found.genres).sorted(), id: \.self) { genre in
                checkRow(genre, on: genres.contains(genre)) { set(genres.toggling(genre)) }
            }
        } footer: {
            Text(footer)
        }
    }

    private func yearField(_ label: String, value: Int?, set: @escaping (Int?) -> Void) -> some View {
        LabeledContent(label) {
            TextField("Any", text: Binding(get: { value.map(String.init) ?? "" },
                                           set: { set(Int($0.filter(\.isNumber))) }))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func checkRow(_ title: String, systemImage: String? = nil, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Youngest audience first for the usual US and UK/Irish ratings, then
    /// anything else alphabetically.
    static func ordered(ratings: some Collection<String>) -> [String] {
        let ladder = ["TV-Y", "TV-Y7", "TV-G", "G", "U", "PG", "TV-PG", "12", "12A", "PG-13", "TV-14", "15", "15A",
                      "16", "R", "TV-MA", "NC-17", "18"]
        let rank = Dictionary(ladder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(Set(ratings)).sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
    }

    /// Names for library folders, or the folder itself for one this phone
    /// doesn't have as a library.
    static func libraryNames(_ folders: Set<String>, in libraries: [LibraryConfig]) -> [String] {
        folders.sorted().map { folder in
            libraries.first { CollectionFilter.normalized(folder: $0.path) == CollectionFilter.normalized(folder: folder) }?.name ?? folder
        }
    }
}

private extension Set {
    func toggling(_ element: Element) -> Set {
        var copy = self
        if copy.remove(element) == nil { copy.insert(element) }
        return copy
    }
}
