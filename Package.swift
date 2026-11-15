// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sidekick",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sidekick",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Sidekick"
        ),
        // Pure note-document module: Foundation only. The app does not depend on it yet.
        .target(
            name: "NoteDocument",
            path: "Sources/NoteDocument"
        ),
        .testTarget(
            name: "NoteDocumentTests",
            dependencies: ["NoteDocument"],
            path: "Tests/NoteDocumentTests"
        ),
        .testTarget(
            name: "SidekickTests",
            dependencies: ["Sidekick"],
            path: "Tests/SidekickTests"
        )
    ]
)
