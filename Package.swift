// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HomeLens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HomeLens", targets: ["HomeLens"]),
        .executable(name: "homelensctl", targets: ["HomeLensCLI"]),
        .library(name: "HomeLensCore", targets: ["HomeLensCore"])
    ],
    targets: [
        .target(
            name: "HomeLensCore",
            path: "Sources/HomeLensCore"
        ),
        .executableTarget(
            name: "HomeLens",
            dependencies: ["HomeLensCore"],
            path: "Sources/HomeLens"
        ),
        .executableTarget(
            name: "HomeLensCLI",
            dependencies: ["HomeLensCore"],
            path: "Sources/HomeLensCLI"
        )
    ]
)
