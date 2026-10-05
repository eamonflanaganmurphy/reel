import ReelCore
import SwiftData
import SwiftUI

extension View {
    /// Where a movie, show, cast member or genre leads, in any of the tabs' stacks.
    func libraryDestinations() -> some View {
        navigationDestination(for: Video.self) { MovieDetailView(video: $0) }
            .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
            .navigationDestination(for: TMDBCastMember.self) { PersonView(person: $0) }
            .navigationDestination(for: GenreRoute.self) { GenreView(route: $0) }
    }
}
