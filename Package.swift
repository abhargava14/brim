// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIIsland",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIIsland", targets: ["AIIsland"]),
        // Named with a dash so it never collides with "AIIsland" on case-insensitive disks.
        .executable(name: "ai-island", targets: ["AIIslandCLI"]),
    ],
    targets: [
        // Log parsing, aggregation, connections and pricing. Foundation only, so it builds and tests anywhere.
        .target(name: "IslandCore"),
        // macOS services shared by the app and the CLI: account connectors, Keychain, licenses.
        .target(
            name: "IslandServices",
            dependencies: ["IslandCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The notch island, menu bar item and settings window.
        .executableTarget(name: "AIIsland", dependencies: ["IslandCore", "IslandServices"]),
        // `ai-island`: connect tools and check usage from the terminal.
        .executableTarget(name: "AIIslandCLI", dependencies: ["IslandCore", "IslandServices"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
