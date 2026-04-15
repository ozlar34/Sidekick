// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sidekick",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/siteline/SwiftUI-Introspect", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sidekick",
            dependencies: [
                .product(name: "SwiftUIIntrospect", package: "SwiftUI-Introspect"),
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
