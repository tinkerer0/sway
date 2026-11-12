// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoloMusicCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MusicCore", targets: ["MusicCore"]),
               .executable(name: "CatalogCheck", targets: ["CatalogCheck"])],
    targets: [
        .target(name: "MusicCore"),
        .executableTarget(name: "CatalogCheck", dependencies: ["MusicCore"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"])
    ]
)
