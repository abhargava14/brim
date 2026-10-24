// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Brim",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BrimApp", targets: ["BrimApp"]),
        // The app target is "BrimApp" so its binary never collides with "brim" on case-insensitive disks.
        .executable(name: "brim", targets: ["BrimCLI"]),
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
        // Readers for this Mac used by the island's tabs: system stats, screen time, music, calendar, weather.
        .target(name: "IslandSystem", dependencies: ["IslandCore"]),
        // The notch island, menu bar item and settings window.
        .executableTarget(name: "BrimApp", dependencies: ["IslandCore", "IslandServices", "IslandSystem"], resources: [.copy("Resources/Logos")]),
        // `brim`: connect tools and check usage from the terminal.
        .executableTarget(name: "BrimCLI", dependencies: ["IslandCore", "IslandServices"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
