/// "More Like This" from what's in the library: TMDB's own recommendations
/// for a title where the library has them, then titles sharing its genres.
public enum MoreLikeThis {
    public struct Candidate: Sendable {
        public var tmdbID: Int?
        public var details: TMDBDetails?

        public init(tmdbID: Int?, details: TMDBDetails?) {
            self.tmdbID = tmdbID
            self.details = details
        }
    }

    /// Indices into `candidates`, best first. Those TMDB relates to `target`
    /// come in its order; then those sharing at least two of its genres (or
    /// its only one), most shared first, then best rated. A title with no
    /// TMDB details has nothing to go on and gets nothing.
    public static func rank(for target: TMDBDetails?, candidates: [Candidate], limit: Int = 15) -> [Int] {
        guard let target else { return [] }
        let position = Dictionary(target.related.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let genres = Set(target.genres)
        let needed = min(2, genres.count)

        var related: [(index: Int, position: Int)] = []
        var similar: [(index: Int, shared: Int, rating: Double)] = []
        for (index, candidate) in candidates.enumerated() {
            if let id = candidate.tmdbID, let p = position[id] {
                related.append((index, p))
            } else if needed > 0 {
                let shared = genres.intersection(candidate.details?.genres ?? []).count
                if shared >= needed { similar.append((index, shared, candidate.details?.rating ?? 0)) }
            }
        }
        related.sort { $0.position < $1.position }
        similar.sort { ($0.shared, $0.rating) > ($1.shared, $1.rating) }
        return Array((related.map(\.index) + similar.map(\.index)).prefix(limit))
    }
}
