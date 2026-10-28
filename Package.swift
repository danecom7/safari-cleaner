// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SafariCleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SafariCleaner",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
