import XCTest
@testable import ReelCore

final class SharedCollectionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let kids = UUID()

    private func collection(_ name: String = "Kids", at: Date, picks: [String: HandPick] = [:]) -> CollectionConfig {
        CollectionConfig(id: kids, name: name, rules: .kidsAndFamily, updatedAt: at, picks: picks)
    }

    private func file(_ device: String, _ collections: [CollectionConfig], deleted: [UUID: Date] = [:]) -> CollectionsFile {
        CollectionsFile(device: device, collections: collections, deleted: deleted)
    }

    func testNewestNameAndFiltersWin() {
        let merged = SharedCollections.merge([
            file("a", [collection("Kids", at: t0)]),
            file("b", [collection("Family", at: t0 + 60)]),
        ])
        XCTAssertEqual(merged.collections.map(\.name), ["Family"])
    }

    func testHandPicksFromBothPhonesStand() {
        let merged = SharedCollections.merge([
            file("a", [collection(at: t0, picks: ["movies/Up": HandPick(included: true, at: t0 + 10)])]),
            file("b", [collection(at: t0 + 60, picks: ["movies/Saw": HandPick(included: false, at: t0 + 20)])]),
        ])
        XCTAssertEqual(merged.collections.first?.picks.count, 2)
        XCTAssertEqual(merged.collections.first?.picked(true), ["movies/Up"])
    }

    func testNewestPickForATitleWins() {
        let merged = SharedCollections.merge([
            file("a", [collection(at: t0, picks: ["movies/Up": HandPick(included: true, at: t0 + 10)])]),
            file("b", [collection(at: t0, picks: ["movies/Up": HandPick(included: nil, at: t0 + 20)])]),
        ])
        XCTAssertEqual(merged.collections.first?.picks["movies/Up"]?.included, .some(nil))
    }

    func testDeletionWinsUnlessChangedSince() {
        let deletedLater = SharedCollections.merge([
            file("a", [collection(at: t0)]),
            file("b", [], deleted: [kids: t0 + 60]),
        ])
        XCTAssertTrue(deletedLater.collections.isEmpty)
        XCTAssertEqual(deletedLater.deleted[kids], t0 + 60)

        let pickedAfter = SharedCollections.merge([
            file("a", [collection(at: t0, picks: ["movies/Up": HandPick(included: true, at: t0 + 120)])]),
            file("b", [], deleted: [kids: t0 + 60]),
        ])
        XCTAssertEqual(pickedAfter.collections.count, 1)
    }

    func testKeepsTheOrderFirstSeen() {
        let other = CollectionConfig(name: "Comfort", rules: CollectionRules(), updatedAt: t0)
        let merged = SharedCollections.merge([
            file("mine", [other, collection(at: t0)]),
            file("theirs", [collection(at: t0), CollectionConfig(name: "New", rules: CollectionRules(), updatedAt: t0)]),
        ])
        XCTAssertEqual(merged.collections.map(\.name), ["Comfort", "Kids", "New"])
    }

    func testReadsCollectionsSavedBeforeSyncing() throws {
        let old = """
        {"id":"\(kids.uuidString)","name":"Kids","rules":{"contents":"both","match":"any","filters":[]},
         "added":["movies/Up"],"removed":["movies/Saw"]}
        """
        let decoded = try JSONDecoder().decode(CollectionConfig.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.updatedAt, CollectionConfig.longAgo)
        XCTAssertEqual(decoded.picked(true), ["movies/Up"])
        XCTAssertEqual(decoded.picked(false), ["movies/Saw"])
    }

    func testHandPickOverridesFilters() {
        var c = collection(at: t0)
        let horror = CollectionCandidate(library: "movies", isMovie: true, year: 2000, details: nil, runtimeMinutes: nil)
        XCTAssertFalse(c.contains(path: "movies/Saw", candidate: horror))
        c.set("movies/Saw", included: true)
        XCTAssertTrue(c.contains(path: "movies/Saw", candidate: horror))
        c.set("movies/Saw", included: nil)
        XCTAssertFalse(c.contains(path: "movies/Saw", candidate: horror))
    }

    func testSaveAndLoadThroughStorage() async throws {
        let storage = MemoryProgressStorage()
        let none = try await SharedCollections.load(from: storage)
        XCTAssertTrue(none.isEmpty)
        let mine = file("phone", [collection(at: t0, picks: ["movies/Up": HandPick(included: true, at: t0)])],
                        deleted: [UUID(): t0])
        try await SharedCollections.save(mine, to: storage)
        let loaded = try await SharedCollections.load(from: storage)
        XCTAssertEqual(loaded, [mine])
    }
}
