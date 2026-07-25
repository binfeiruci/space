// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpaceGhostty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "GhosttyTerminal",
            targets: ["GhosttyTerminal"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/ghostty"),
                .copy("Resources/terminfo"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
