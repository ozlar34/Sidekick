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
        .testTarget(
            name: "SidekickTests",
            dependencies: ["Sidekick"],
            path: "Tests/SidekickTests"
        )
    ]
)
