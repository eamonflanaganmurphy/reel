// swift-tools-version:6.0
import PackageDescription

// Everything that isn't UI or playback: parsing release names, walking the
// share, and TMDB lookups. Kept free of UIKit/SwiftData so it builds and tests
// on Linux as well as in the app.
let package = Package(
    name: "ReelCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReelCore", targets: ["ReelCore"]),
        .executable(name: "reelscan", targets: ["reelscan"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2", .upToNextMinor(from: "4.0.3")),
    ],
    targets: [
        .target(
            name: "ReelCore",
            dependencies: [.product(name: "AMSMB2", package: "AMSMB2")]
        ),
        .executableTarget(name: "reelscan", dependencies: ["ReelCore"]),
        .testTarget(name: "ReelCoreTests", dependencies: ["ReelCore"]),
    ]
)
